# encoding: UTF-8

require 'thread'
require 'net/http'
require 'open-uri'
require 'fileutils'
require 'cgi'
require 'json'
require 'time'
require 'concurrent-ruby'
require 'logger'
require 'zlib'
require 'stringio'
require_relative 'wayback_machine_downloader/tidy_bytes'
require_relative 'wayback_machine_downloader/to_regex'
require_relative 'wayback_machine_downloader/archive_api'

class ConnectionPool
  MAX_AGE = 300
  CLEANUP_INTERVAL = 60
  DEFAULT_TIMEOUT = 30
  MAX_RETRIES = 3

  def initialize(size)
    @size = size
    @pool = Concurrent::Map.new
    @creation_times = Concurrent::Map.new
    @cleanup_thread = schedule_cleanup
  end

  def with_connection(&block)
    conn = acquire_connection
    begin
      yield conn
    ensure
      release_connection(conn)
    end
  end

  def shutdown
    @cleanup_thread&.exit
    @pool.each_value { |conn| conn.finish if conn&.started? }
    @pool.clear
    @creation_times.clear
  end

  private

  def acquire_connection
    thread_id = Thread.current.object_id
    conn = @pool[thread_id]

    if should_create_new?(conn)
      conn&.finish if conn&.started?
      conn = create_connection
      @pool[thread_id] = conn
      @creation_times[thread_id] = Time.now
    end

    conn
  end

  def release_connection(conn)
    return unless conn
    if conn.started? && Time.now - @creation_times[Thread.current.object_id] > MAX_AGE
      conn.finish
      @pool.delete(Thread.current.object_id)
      @creation_times.delete(Thread.current.object_id)
    end
  end

  def should_create_new?(conn)
    return true if conn.nil?
    return true unless conn.started?
    return true if Time.now - @creation_times[Thread.current.object_id] > MAX_AGE
    false
  end

  def create_connection
    http = Net::HTTP.new("web.archive.org", 443)
    http.use_ssl = true
    http.read_timeout = DEFAULT_TIMEOUT
    http.open_timeout = DEFAULT_TIMEOUT
    http.keep_alive_timeout = 30
    http.max_retries = MAX_RETRIES
    http.start
    http
  end

  def schedule_cleanup
    Thread.new do
      loop do
        cleanup_old_connections
        sleep CLEANUP_INTERVAL
      end
    end
  end

  def cleanup_old_connections
    current_time = Time.now
    @creation_times.each do |thread_id, creation_time|
      if current_time - creation_time > MAX_AGE
        conn = @pool[thread_id]
        conn&.finish if conn&.started?
        @pool.delete(thread_id)
        @creation_times.delete(thread_id)
      end
    end
  end
end

class WaybackMachineDownloader

  include ArchiveAPI

  VERSION = "2.3.3"
  DEFAULT_TIMEOUT = 30
  MAX_RETRIES = 3
  RETRY_DELAY = 2
  RATE_LIMIT = 0.25  # Delay between requests in seconds
  CONNECTION_POOL_SIZE = 10
  MEMORY_BUFFER_SIZE = 16384  # 16KB chunks
  STATE_CDX_FILENAME = ".cdx.json"
  STATE_DB_FILENAME = ".downloaded.txt"

  attr_accessor :base_url, :exact_url, :directory, :all_timestamps,
    :from_timestamp, :to_timestamp, :only_filter, :exclude_filter,
    :all, :maximum_pages, :threads_count, :logger, :reset, :keep

  def initialize params
    validate_params(params)
    @base_url = params[:base_url]
    @exact_url = params[:exact_url]
    @directory = params[:directory]
    @all_timestamps = params[:all_timestamps]
    @from_timestamp = params[:from_timestamp].to_i
    @to_timestamp = params[:to_timestamp].to_i
    @only_filter = params[:only_filter]
    @exclude_filter = params[:exclude_filter]
    @all = params[:all]
    @maximum_pages = params[:maximum_pages] ? params[:maximum_pages].to_i : 100
    @threads_count = [params[:threads_count].to_i, 1].max
    @rewritten = params[:rewritten]
    @reset = params[:reset]
    @keep = params[:keep]
    @timeout = params[:timeout] || DEFAULT_TIMEOUT
    @logger = setup_logger
    @failed_downloads = Concurrent::Array.new
    @connection_pool = ConnectionPool.new(CONNECTION_POOL_SIZE)
    @db_mutex = Mutex.new

    handle_reset
  end

  def backup_name
    if @base_url.include? '//'
      @base_url.split('/')[2]
    else
      @base_url
    end
  end

  def backup_path
    if @directory
      if @directory[-1] == '/'
        @directory
      else
        @directory + '/'
      end
    else
      'websites/' + backup_name + '/'
    end
  end

  def cdx_path
    File.join(backup_path, STATE_CDX_FILENAME)
  end

  def db_path
    File.join(backup_path, STATE_DB_FILENAME)
  end

  def handle_reset
    if @reset
      puts "Resetting download state..."
      FileUtils.rm_f(cdx_path)
      FileUtils.rm_f(db_path)
      puts "Removed state files: #{cdx_path}, #{db_path}"
    end
  end

  def match_only_filter file_url
    if @only_filter
      only_filter_regex = @only_filter.to_regex
      if only_filter_regex
        only_filter_regex =~ file_url
      else
        file_url.downcase.include? @only_filter.downcase
      end
    else
      true
    end
  end

  def match_exclude_filter file_url
    if @exclude_filter
      exclude_filter_regex = @exclude_filter.to_regex
      if exclude_filter_regex
        exclude_filter_regex =~ file_url
      else
        file_url.downcase.include? @exclude_filter.downcase
      end
    else
      false
    end
  end

  def get_all_snapshots_to_consider
    if File.exist?(cdx_path) && !@reset
      puts "Loading snapshot list from #{cdx_path}"
      begin
        snapshot_list_to_consider = JSON.parse(File.read(cdx_path))
        puts "Loaded #{snapshot_list_to_consider.length} snapshots from cache."
        puts
        return Concurrent::Array.new(snapshot_list_to_consider)
      rescue JSON::ParserError => e
        puts "Error reading snapshot cache file #{cdx_path}: #{e.message}. Refetching..."
        FileUtils.rm_f(cdx_path)
      rescue => e
        puts "Error loading snapshot cache #{cdx_path}: #{e.message}. Refetching..."
        FileUtils.rm_f(cdx_path)
      end
    end

    snapshot_list_to_consider = Concurrent::Array.new
    mutex = Mutex.new

    puts "Getting snapshot pages from Wayback Machine API..."

    # Fetch the initial set of snapshots, sequentially
    @connection_pool.with_connection do |connection|
      initial_list = get_raw_list_from_api(@base_url, nil, connection)
      mutex.synchronize do
        snapshot_list_to_consider.concat(initial_list)
        print "."
      end
    end

    # Fetch additional pages if the exact URL flag is not set
    unless @exact_url
      page_index = 0
      batch_size = [@threads_count, 5].min
      continue_fetching = true

      while continue_fetching && page_index < @maximum_pages
        # Determine the range of pages to fetch in this batch
        end_index = [page_index + batch_size, @maximum_pages].min
        current_batch = (page_index...end_index).to_a

        # Create futures for concurrent API calls
        futures = current_batch.map do |page|
          Concurrent::Future.execute do
            result = nil
            @connection_pool.with_connection do |connection|
              result = get_raw_list_from_api("#{@base_url}/*", page, connection)
            end
            [page, result]
          end
        end

        results = []

        futures.each do |future|
          begin
            results << future.value
          rescue => e
            puts "\nError fetching page #{future}: #{e.message}"
          end
        end

        # Sort results by page number to maintain order
        results.sort_by! { |page, _| page }

        # Process results and check for empty pages
        results.each do |page, result|
          if result.empty?
            continue_fetching = false
            break
          else
            mutex.synchronize do
              snapshot_list_to_consider.concat(result)
              print "."
            end
          end
        end

        page_index = end_index

        sleep(RATE_LIMIT) if continue_fetching
      end
    end

    puts " found #{snapshot_list_to_consider.length} snapshots."

    # Save the fetched list to the cache file
    begin
      FileUtils.mkdir_p(File.dirname(cdx_path))
      File.write(cdx_path, JSON.pretty_generate(snapshot_list_to_consider.to_a)) # Convert Concurrent::Array back to Array for JSON
      puts "Saved snapshot list to #{cdx_path}"
    rescue => e
      puts "Error saving snapshot cache to #{cdx_path}: #{e.message}"
    end
    puts

    snapshot_list_to_consider
  end

  def get_file_list_curated
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')
      file_id = file_url.split('/')[3..-1].join('/')
      file_id = CGI::unescape file_id
      file_id = file_id.tidy_bytes unless file_id == ""
      if file_id.nil?
        puts "Malformed file url, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          puts "File url matches exclude filter, ignoring: #{file_url}"
        elsif not match_only_filter(file_url)
          puts "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id]
          unless file_list_curated[file_id][:timestamp] > file_timestamp
            file_list_curated[file_id] = {file_url: file_url, timestamp: file_timestamp}
          end
        else
          file_list_curated[file_id] = {file_url: file_url, timestamp: file_timestamp}
        end
      end
    end
    file_list_curated
  end

  def get_file_list_all_timestamps
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')
      file_id = file_url.split('/')[3..-1].join('/')
      file_id_and_timestamp = [file_timestamp, file_id].join('/')
      file_id_and_timestamp = CGI::unescape file_id_and_timestamp
      file_id_and_timestamp = file_id_and_timestamp.tidy_bytes unless file_id_and_timestamp == ""
      if file_id.nil?
        puts "Malformed file url, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          puts "File url matches exclude filter, ignoring: #{file_url}"
        elsif not match_only_filter(file_url)
          puts "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id_and_timestamp]
          puts "Duplicate file and timestamp combo, ignoring: #{file_id}" if @verbose
        else
          file_list_curated[file_id_and_timestamp] = {file_url: file_url, timestamp: file_timestamp}
        end
      end
    end
    puts "file_list_curated: " + file_list_curated.count.to_s
    file_list_curated
  end


  def get_file_list_by_timestamp
    if @all_timestamps
      file_list_curated = get_file_list_all_timestamps
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    else
      file_list_curated = get_file_list_curated
      file_list_curated = file_list_curated.sort_by { |k,v| v[:timestamp] }.reverse
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    end
  end

  def list_files
    # retrieval produces its own output
    @orig_stdout = $stdout
    $stdout = $stderr
    files = get_file_list_by_timestamp
    $stdout = @orig_stdout
    puts "["
    files[0...-1].each do |file|
      puts file.to_json + ","
    end
    puts files[-1].to_json
    puts "]"
  end

  def load_downloaded_ids
    downloaded_ids = Set.new
    if File.exist?(db_path) && !@reset
      puts "Loading list of already downloaded files from #{db_path}"
      begin
        File.foreach(db_path) { |line| downloaded_ids.add(line.strip) }
      rescue => e
        puts "Error reading downloaded files list #{db_path}: #{e.message}. Assuming no files downloaded."
        downloaded_ids.clear
      end
    end
    downloaded_ids
  end

  def append_to_db(file_id)
    @db_mutex.synchronize do
      begin
        FileUtils.mkdir_p(File.dirname(db_path))
        File.open(db_path, 'a') { |f| f.puts(file_id) }
      rescue => e
        @logger.error("Failed to append downloaded file ID #{file_id} to #{db_path}: #{e.message}")
      end
    end
  end

  def download_files
    start_time = Time.now
    puts "Downloading #{@base_url} to #{backup_path} from Wayback Machine archives."

    FileUtils.mkdir_p(backup_path)

    # Load the list of files to potentially download
    files_to_download = file_list_by_timestamp

    if files_to_download.empty?
      puts "No files found matching criteria."
      cleanup
      return
    end

    total_files = files_to_download.count
    puts "#{total_files} files found matching criteria."

    # Load IDs of already downloaded files
    downloaded_ids = load_downloaded_ids
    files_to_process = files_to_download.reject do |file_info|
      downloaded_ids.include?(file_info[:file_id])
    end

    remaining_count = files_to_process.count
    skipped_count = total_files - remaining_count

    if skipped_count > 0
      puts "Found #{skipped_count} previously downloaded files, skipping them."
    end

    if remaining_count == 0
      puts "All matching files have already been downloaded."
      cleanup
      return
    end

    puts "#{remaining_count} files to download:"

    @processed_file_count = 0
    @total_to_download = remaining_count
    @download_mutex = Mutex.new

    thread_count = [@threads_count, CONNECTION_POOL_SIZE].min
    pool = Concurrent::FixedThreadPool.new(thread_count)

    files_to_process.each do |file_remote_info|
      pool.post do
        download_success = false
        begin
          @connection_pool.with_connection do |connection|
            result_message = download_file(file_remote_info, connection)
            # for now, assume success if no exception and message doesn't indicate error/skip
            if result_message && !result_message.downcase.include?('error') && !result_message.downcase.include?('failed') && !result_message.downcase.include?('skipping') && !result_message.downcase.include?('already exists')
               download_success = true
            end
            @download_mutex.synchronize do
              @processed_file_count += 1
              # adjust progress message to reflect remaining files
              progress_message = result_message.sub(/\(#{@processed_file_count}\/\d+\)/, "(#{@processed_file_count}/#{@total_to_download})") if result_message
              puts progress_message if progress_message
            end
          end
          # sppend to DB only after successful download outside the connection block
          if download_success
            append_to_db(file_remote_info[:file_id])
          end
        rescue => e
          @logger.error("Error processing file #{file_remote_info[:file_url]}: #{e.message}")
           @download_mutex.synchronize do
              @processed_file_count += 1
           end
        end
        sleep(RATE_LIMIT)
      end
    end

    pool.shutdown
    pool.wait_for_termination

    end_time = Time.now
    puts "\nDownload finished in #{(end_time - start_time).round(2)}s."
    puts "Results saved in #{backup_path}"
    cleanup
  end

  def structure_dir_path dir_path
    begin
      FileUtils::mkdir_p dir_path unless File.exist? dir_path
    rescue Errno::EEXIST => e
      error_to_string = e.to_s
      puts "# #{error_to_string}"
      if error_to_string.include? "File exists @ dir_s_mkdir - "
        file_already_existing = error_to_string.split("File exists @ dir_s_mkdir - ")[-1]
      elsif error_to_string.include? "File exists - "
        file_already_existing = error_to_string.split("File exists - ")[-1]
      else
        raise "Unhandled directory restructure error # #{error_to_string}"
      end
      file_already_existing_temporary = file_already_existing + '.temp'
      file_already_existing_permanent = file_already_existing + '/index.html'
      FileUtils::mv file_already_existing, file_already_existing_temporary
      FileUtils::mkdir_p file_already_existing
      FileUtils::mv file_already_existing_temporary, file_already_existing_permanent
      puts "#{file_already_existing} -> #{file_already_existing_permanent}"
      structure_dir_path dir_path
    end
  end

  def download_file (file_remote_info, http)
    current_encoding = "".encoding
    file_url = file_remote_info[:file_url].encode(current_encoding)
    file_id = file_remote_info[:file_id]
    file_timestamp = file_remote_info[:timestamp]
    original_file_id = @all_timestamps ? file_id.split('/', 2)[1] : file_id
    file_path_elements = original_file_id.split('/')

    if original_file_id == ""
      dir_path = backup_path
      file_path = backup_path + 'index.html'
    elsif file_url[-1] == '/' or not file_path_elements[-1].include? '.'
      dir_path = backup_path + file_path_elements[0..-1].join('/')
      file_path = backup_path + file_path_elements[0..-1].join('/') + '/index.html'
    else
      dir_path = backup_path + file_path_elements[0..-2].join('/')
      file_path = backup_path + file_path_elements[0..-1].join('/')
    end
    if Gem.win_platform?
      dir_path = dir_path.gsub(/[:*?&=<>\\|]/) {|s| '%' + s.ord.to_s(16) }
      file_path = file_path.gsub(/[:*?&=<>\\|]/) {|s| '%' + s.ord.to_s(16) }
    end

    # check existence *before* download attempt
    # this handles cases where a file was created manually or by a previous partial run without a .db entry
    if File.exist? file_path
       return "#{file_url} # #{file_path} already exists. (#{@processed_file_count + 1}/#{@total_to_download})"
    end

    begin
      structure_dir_path dir_path
      download_with_retry(file_path, file_url, file_timestamp, http)
      "#{file_url} -> #{file_path} (#{@processed_file_count + 1}/#{@total_to_download})"
    rescue StandardError => e
      msg = "Failed: #{file_url} # #{e} (#{@processed_file_count + 1}/#{@total_to_download})"
      if not @all and File.exist?(file_path) and File.size(file_path) == 0
        File.delete(file_path)
        msg += "\n#{file_path} was empty and was removed."
      end
      msg
    end
  end

  def file_queue
    @file_queue ||= file_list_by_timestamp.each_with_object(Queue.new) { |file_info, q| q << file_info }
  end

  def file_list_by_timestamp
    @file_list_by_timestamp ||= get_file_list_by_timestamp
  end

  private

  def validate_params(params)
    raise ArgumentError, "Base URL is required" unless params[:base_url]
    raise ArgumentError, "Maximum pages must be positive" if params[:maximum_pages] && params[:maximum_pages].to_i <= 0
  end

  def setup_logger
    logger = Logger.new(STDOUT)
    logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO
    logger.formatter = proc do |severity, datetime, progname, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
    end
    logger
  end

  def download_with_retry(file_path, file_url, file_timestamp, connection, redirect_count = 0)
    retries = 0
    begin
      wayback_url = if @rewritten
        "https://web.archive.org/web/#{file_timestamp}/#{file_url}"
      else
        "https://web.archive.org/web/#{file_timestamp}id_/#{file_url}"
      end

      request = Net::HTTP::Get.new(URI(wayback_url))
      request["Connection"] = "keep-alive"
      request["User-Agent"] = "WaybackMachineDownloader/#{VERSION}"
      request["Accept-Encoding"] = "gzip, deflate"

      response = connection.request(request)

      case response
      when Net::HTTPSuccess
        File.open(file_path, "wb") do |file|
          body = response.body
          if response['content-encoding'] == 'gzip' && body && !body.empty?
            begin
              gz = Zlib::GzipReader.new(StringIO.new(body))
              decompressed_body = gz.read
              gz.close
              file.write(decompressed_body)
            rescue Zlib::GzipFile::Error => e
              @logger.warn("Failure decompressing gzip file #{file_url}: #{e.message}")
              file.write(body)
            end
          else
            file.write(body) if body
          end
        end
      when Net::HTTPRedirection
        raise "Too many redirects for #{file_url}" if redirect_count >= 2
        location = response['location']
        @logger.warn("Redirect found for #{file_url} -> #{location}")
        return download_with_retry(file_path, location, file_timestamp, connection, redirect_count + 1)
      when Net::HTTPTooManyRequests
        sleep(RATE_LIMIT * 2)
        raise "Rate limited, retrying..."
      when Net::HTTPNotFound
        @logger.warn("File not found, skipping: #{file_url}")
        return
      else
        raise "HTTP Error: #{response.code} #{response.message}"
      end

    rescue StandardError => e
      if retries < MAX_RETRIES
        retries += 1
        @logger.warn("Retry #{retries}/#{MAX_RETRIES} for #{file_url}: #{e.message}")
        sleep(RETRY_DELAY * retries)
        retry
      else
        @failed_downloads << {url: file_url, error: e.message}
        raise e
      end
    end
  end

  def cleanup
    @connection_pool.shutdown

    if @failed_downloads.any?
      @logger.error("Download completed with errors.")
      @logger.error("Failed downloads summary:")
      @failed_downloads.each do |failure|
        @logger.error("  #{failure[:url]} - #{failure[:error]}")
      end
      unless @reset
         puts "State files kept due to download errors: #{cdx_path}, #{db_path}"
         return
      end
    end

    if !@keep || @reset
        puts "Cleaning up state files..." unless @keep && !@reset
        FileUtils.rm_f(cdx_path)
        FileUtils.rm_f(db_path)
    elsif @keep
        puts "Keeping state files as requested: #{cdx_path}, #{db_path}"
    end
  end
end
