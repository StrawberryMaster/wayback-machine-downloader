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
require 'digest'
require_relative 'wayback_machine_downloader/tidy_bytes'
require_relative 'wayback_machine_downloader/to_regex'
require_relative 'wayback_machine_downloader/archive_api'
require_relative 'wayback_machine_downloader/subdom_processor'
require_relative 'wayback_machine_downloader/url_rewrite'

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
  include SubdomainProcessor

  VERSION = "2.4.2"
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
    :all, :maximum_pages, :threads_count, :logger, :reset, :keep, :rewrite,
    :snapshot_at

  def initialize params
    validate_params(params)
    @base_url = params[:base_url]&.tidy_bytes
    @exact_url = params[:exact_url]
    if params[:directory]
      sanitized_dir = params[:directory].tidy_bytes
      @directory = File.expand_path(sanitized_dir)
    else
      @directory = nil
    end
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
    @rewrite = params[:rewrite] || false
    @recursive_subdomains = params[:recursive_subdomains] || false
    @subdomain_depth = params[:subdomain_depth] || 1
    @snapshot_at = params[:snapshot_at] ? params[:snapshot_at].to_i : nil

    # URL for rejecting invalid/unencoded wayback urls
    @url_regexp = /^(([A-Za-z][A-Za-z0-9+.-]*):((\/\/(((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=]))+)(:([0-9]*))?)(((\/((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=])|:|@)*))*)))|((\/(((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=])|:|@)+)(\/((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=])|:|@)*))*)?))|((((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=])|:|@)+)(\/((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=])|:|@)*))*)))(\?((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=])|:|@)|\/|\?)*)?(\#((([A-Za-z0-9._~-])|(%[ABCDEFabcdef0-9][ABCDEFabcdef0-9])|([!$&'('')'*+,;=])|:|@)|\/|\?)*)?)$/

    handle_reset
  end

  def backup_name
    url_to_process = @base_url.end_with?('/*') ? @base_url.chomp('/*') : @base_url
    raw = if url_to_process.include?('//')
      url_to_process.split('/')[2]
    else
      url_to_process
    end

    # sanitize for Windows (and safe cross-platform) to avoid ENOTDIR on mkdir (colon in host:port)
    if Gem.win_platform?
      raw = raw.gsub(/[:*?"<>|]/, '_')
      raw = raw.gsub(/[ .]+\z/, '')
    end
    raw = 'site' if raw.nil? || raw.empty?
    raw
  end

  def backup_path
    if @directory
      # because @directory is already an absolute path, we just ensure it exists
      @directory
    else
      # ensure the default path is absolute and normalized
      File.expand_path(File.join('websites', backup_name))
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
      only_filter_regex = @only_filter.to_regex(detect: true)
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
      exclude_filter_regex = @exclude_filter.to_regex(detect: true)
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
      initial_list ||= []
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
            result ||= []
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
          if result.nil? || result.empty?
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

  # Get a composite snapshot file list for a specific timestamp
  def get_composite_snapshot_file_list(target_timestamp)
    file_versions = {}
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')
      next if file_timestamp.to_i > target_timestamp

      raw_tail = file_url.split('/')[3..-1]&.join('/')
      file_id = sanitize_and_prepare_id(raw_tail, file_url)
      next if file_id.nil?
      next if match_exclude_filter(file_url)
      next unless match_only_filter(file_url)

      if !file_versions[file_id] || file_versions[file_id][:timestamp].to_i < file_timestamp.to_i
        file_versions[file_id] = { file_url: file_url, timestamp: file_timestamp, file_id: file_id }
      end
    end
    file_versions.values
  end

  # Returns a list of files for the composite snapshot
  def get_file_list_composite_snapshot(target_timestamp)
    file_list = get_composite_snapshot_file_list(target_timestamp)
    file_list = file_list.sort_by { |_,v| v[:timestamp].to_s }.reverse
    file_list.map do |file_remote_info|
      file_remote_info[1][:file_id] = file_remote_info[0]
      file_remote_info[1]
    end
  end

  def get_file_list_curated
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')

      raw_tail = file_url.split('/')[3..-1]&.join('/')
      file_id = sanitize_and_prepare_id(raw_tail, file_url)
      if file_id.nil?
        puts "Malformed file url, ignoring: #{file_url}"
        next
      end

      if file_id.include?('<') || file_id.include?('>')
        puts "Invalid characters in file_id after sanitization, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          puts "File url matches exclude filter, ignoring: #{file_url}"
        elsif !match_only_filter(file_url)
          puts "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id]
          unless file_list_curated[file_id][:timestamp] > file_timestamp
            file_list_curated[file_id] = { file_url: file_url, timestamp: file_timestamp }
          end
        else
          file_list_curated[file_id] = { file_url: file_url, timestamp: file_timestamp }
        end
      end
    end
    file_list_curated
  end

  def get_file_list_all_timestamps
    file_list_curated = Hash.new
    get_all_snapshots_to_consider.each do |file_timestamp, file_url|
      next unless file_url.include?('/')

      raw_tail = file_url.split('/')[3..-1]&.join('/')
      file_id = sanitize_and_prepare_id(raw_tail, file_url)
      if file_id.nil?
        puts "Malformed file url, ignoring: #{file_url}"
        next
      end

      file_id_and_timestamp_raw = [file_timestamp, file_id].join('/')
      file_id_and_timestamp = sanitize_and_prepare_id(file_id_and_timestamp_raw, file_url)
      if file_id_and_timestamp.nil?
        puts "Malformed file id/timestamp combo, ignoring: #{file_url}"
        next
      end

      if file_id_and_timestamp.include?('<') || file_id_and_timestamp.include?('>')
        puts "Invalid characters in file_id after sanitization, ignoring: #{file_url}"
      else
        if match_exclude_filter(file_url)
          puts "File url matches exclude filter, ignoring: #{file_url}"
        elsif !match_only_filter(file_url)
          puts "File url doesn't match only filter, ignoring: #{file_url}"
        elsif file_list_curated[file_id_and_timestamp]
          # duplicate combo, ignore silently (verbose flag not shown here)
        else
          file_list_curated[file_id_and_timestamp] = { file_url: file_url, timestamp: file_timestamp }
        end
      end
    end
    puts "file_list_curated: " + file_list_curated.count.to_s
    file_list_curated
  end


  def get_file_list_by_timestamp
    if @snapshot_at
      @file_list_by_snapshot_at ||= get_composite_snapshot_file_list(@snapshot_at)
    elsif @all_timestamps
      file_list_curated = get_file_list_all_timestamps
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    else
      file_list_curated = get_file_list_curated
      file_list_curated = file_list_curated.sort_by { |_,v| v[:timestamp].to_s }.reverse
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

  def processing_files(pool, files_to_process)
    files_to_process.each do |file_remote_info|
      pool.post do
        download_success = false
        begin
          @connection_pool.with_connection do |connection|
            result_message = download_file(file_remote_info, connection)
            # assume download success if the result message contains ' -> '
            if result_message && result_message.include?(' -> ')
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

    processing_files(pool, files_to_process)

    pool.shutdown
    pool.wait_for_termination

    end_time = Time.now
    puts "\nDownload finished in #{(end_time - start_time).round(2)}s."

    # process subdomains if enabled
    if @recursive_subdomains
      subdomain_start_time = Time.now
      process_subdomains
      subdomain_end_time = Time.now
      subdomain_time = (subdomain_end_time - subdomain_start_time).round(2)
      puts "Subdomain processing finished in #{subdomain_time}s."
    end

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

  def rewrite_urls_to_relative(file_path)
    return unless File.exist?(file_path)
    
    file_ext = File.extname(file_path).downcase
    
    begin
      content = File.binread(file_path)

      if file_ext == '.html' || file_ext == '.htm'
        encoding = content.match(/<meta\s+charset=["']?([^"'>]+)/i)&.captures&.first || 'UTF-8'
        content.force_encoding(encoding) rescue content.force_encoding('UTF-8')
      else
        content.force_encoding('UTF-8')
      end

      # URLs in HTML attributes
      rewrite_html_attr_urls(content)
      
      # URLs in CSS
      rewrite_css_urls(content)
      
      # URLs in JavaScript
      rewrite_js_urls(content)
      
      # for URLs in HTML attributes that start with a single slash
      content.gsub!(/(\s(?:href|src|action|data-src|data-url)=["'])\/([^"'\/][^"']*)(["'])/i) do
        prefix, path, suffix = $1, $2, $3
        "#{prefix}./#{path}#{suffix}"
      end
      
      # for URLs in CSS that start with a single slash
      content.gsub!(/url\(\s*["']?\/([^"'\)\/][^"'\)]*?)["']?\s*\)/i) do
        path = $1
        "url(\"./#{path}\")"
      end

      # save the modified content back to the file
      File.binwrite(file_path, content)
      puts "Rewrote URLs in #{file_path} to be relative."
    rescue Errno::ENOENT => e
      @logger.warn("Error reading file #{file_path}: #{e.message}")
    end
  end

  def download_file (file_remote_info, http)
    current_encoding = "".encoding
    file_url = file_remote_info[:file_url].encode(current_encoding)
    file_id = file_remote_info[:file_id]
    file_timestamp = file_remote_info[:timestamp]
    
    # sanitize file_id to ensure it is a valid path component
    raw_path_elements = file_id.split('/')

    sanitized_path_elements = raw_path_elements.map do |element|
      if Gem.win_platform?
        # for Windows, we need to sanitize path components to avoid invalid characters
        # this prevents issues with file names that contain characters not allowed in
        # Windows file systems. See # https://docs.microsoft.com/en-us/windows/win32/fileio/naming-a-file#naming-conventions
        element.gsub(/[:\*?"<>\|\&\=\/\\]/) { |match| '%' + match.ord.to_s(16).upcase }
      else
        element
      end
    end
    
    current_backup_path = backup_path

    if file_id == ""
      dir_path = current_backup_path
      file_path = File.join(dir_path, 'index.html')
    elsif file_url[-1] == '/' || (sanitized_path_elements.last && !sanitized_path_elements.last.include?('.'))
      # if file_id is a directory, we treat it as such
      dir_path = File.join(current_backup_path, *sanitized_path_elements)
      file_path = File.join(dir_path, 'index.html')
    else
      # if file_id is a file, we treat it as such
      filename = sanitized_path_elements.pop
      dir_path = File.join(current_backup_path, *sanitized_path_elements)
      file_path = File.join(dir_path, filename)
    end

    # check existence *before* download attempt
    # this handles cases where a file was created manually or by a previous partial run without a .db entry
    if File.exist? file_path
       return "#{file_url} # #{file_path} already exists. (#{@processed_file_count + 1}/#{@total_to_download})"
    end

    begin
      structure_dir_path dir_path
      status = download_with_retry(file_path, file_url, file_timestamp, http)

      case status
      when :saved
        if @rewrite && File.extname(file_path) =~ /\.(html?|css|js)$/i
          rewrite_urls_to_relative(file_path)
        end
        "#{file_url} -> #{file_path} (#{@processed_file_count + 1}/#{@total_to_download})"
      when :skipped_not_found
        "Skipped (not found): #{file_url} (#{@processed_file_count + 1}/#{@total_to_download})"
      else
        # ideally, this case should not be reached if download_with_retry behaves as expected.
        @logger.warn("Unknown status from download_with_retry for #{file_url}: #{status}")
        "Unknown status for #{file_url}: #{status} (#{@processed_file_count + 1}/#{@total_to_download})"
      end
    rescue StandardError => e
      msg = "Failed: #{file_url} # #{e} (#{@processed_file_count + 1}/#{@total_to_download})"
      if File.exist?(file_path) and File.size(file_path) == 0
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
    if @snapshot_at
      @file_list_by_snapshot_at ||= get_composite_snapshot_file_list(@snapshot_at)
    elsif @all_timestamps
      file_list_curated = get_file_list_all_timestamps
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    else
      file_list_curated = get_file_list_curated
      file_list_curated = file_list_curated.sort_by { |_,v| v[:timestamp].to_s }.reverse
      file_list_curated.map do |file_remote_info|
        file_remote_info[1][:file_id] = file_remote_info[0]
        file_remote_info[1]
      end
    end
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
    
  # safely sanitize a file id (or id+timestamp)
  def sanitize_and_prepare_id(raw, file_url)
    return nil if raw.nil?
    return ""  if raw.empty?
    original = raw.dup
    begin
      # work on a binary copy to avoid premature encoding errors
      raw = raw.dup.force_encoding(Encoding::BINARY)

      # percent-decode (repeat until stable in case of double-encoding)
      loop do
        decoded = raw.gsub(/%([0-9A-Fa-f]{2})/) { [$1].pack('H2') }
        break if decoded == raw
        raw = decoded
      end

      # try tidy_bytes
      begin
        raw = raw.tidy_bytes
      rescue StandardError
        # fallback: scrub to UTF-8
        raw = raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
      end

      # ensure UTF-8 and scrub again
      unless raw.encoding == Encoding::UTF_8 && raw.valid_encoding?
        raw = raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
      end

      # strip HTML/comment artifacts & control chars
      raw.gsub!(/<!--+/, '')
      raw.gsub!(/[\x00-\x1F]/, '')

      # split query; hash it for stable short name
      path_part, query_part = raw.split('?', 2)
      if query_part && !query_part.empty?
        q_digest = Digest::SHA256.hexdigest(query_part)[0, 12]
        if path_part.include?('.')
          pre, _sep, post = path_part.rpartition('.')
          path_part = "#{pre}__q#{q_digest}.#{post}"
        else
          path_part = "#{path_part}__q#{q_digest}"
        end
      end
      raw = path_part

      # collapse slashes & trim leading slash
      raw.gsub!(%r{/+}, '/')
      raw.sub!(%r{\A/}, '')

      # segment-wise sanitation
      raw = raw.split('/').map do |segment|
        seg = segment.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
        seg = seg.gsub(/[:*?"<>|\\]/) { |c| "%#{c.ord.to_s(16).upcase}" }
        seg = seg.gsub(/[ .]+\z/, '') if Gem.win_platform?
        seg.empty? ? '_' : seg
      end.join('/')

      # remove any remaining angle brackets
      raw.tr!('<>', '')

      # final fallback if empty
      raw = "file__#{Digest::SHA1.hexdigest(original)[0,10]}" if raw.nil? || raw.empty?

      raw
    rescue => e
      @logger&.warn("Failed to sanitize file id from #{file_url}: #{e.message}")
      # deterministic fallback – never return nil so caller won’t mark malformed
      "file__#{Digest::SHA1.hexdigest(original)[0,10]}"
    end
  end

  # wrap URL in parentheses if it contains characters that commonly break unquoted
  # Windows CMD usage (e.g., &). This is only for display; user still must quote
  # when invoking manually.
  def safe_display_url(url)
    return url unless url && url.match?(/[&]/)
    "(#{url})"
  end

  def download_with_retry(file_path, file_url, file_timestamp, connection, redirect_count = 0)
    retries = 0
    begin
      wayback_url = if @rewritten
        "https://web.archive.org/web/#{file_timestamp}/#{file_url}"
      else
        "https://web.archive.org/web/#{file_timestamp}id_/#{file_url}"
      end

      # Escape square brackets because they are not valid in URI()
      wayback_url = wayback_url.gsub('[', '%5B').gsub(']', '%5D')

      # reject invalid/unencoded wayback_url, behaving as if the resource weren't found
      if not @url_regexp.match?(wayback_url)
          @logger.warn("Skipped #{file_url}: invalid URL")
          return :skipped_not_found
      end

      request = Net::HTTP::Get.new(URI(wayback_url))
      request["Connection"] = "keep-alive"
      request["User-Agent"] = "WaybackMachineDownloader/#{VERSION}"
      request["Accept-Encoding"] = "gzip, deflate"

      response = connection.request(request)

      save_response_body = lambda do
        File.open(file_path, "wb") do |file|
          body = response.body
          if response['content-encoding'] == 'gzip' && body && !body.empty?
            begin
              gz = Zlib::GzipReader.new(StringIO.new(body))
              decompressed_body = gz.read
              gz.close
              file.write(decompressed_body)
            rescue Zlib::GzipFile::Error => e
              @logger.warn("Failure decompressing gzip file #{file_url}: #{e.message}. Writing raw body.")
              file.write(body)
            end
          else
            file.write(body) if body
          end
        end
      end

      if @all
        case response
        when Net::HTTPSuccess, Net::HTTPRedirection, Net::HTTPClientError, Net::HTTPServerError
          save_response_body.call
          if response.is_a?(Net::HTTPRedirection)
            @logger.info("Saved redirect page for #{file_url} (status #{response.code}).")
          elsif response.is_a?(Net::HTTPClientError) || response.is_a?(Net::HTTPServerError)
            @logger.info("Saved error page for #{file_url} (status #{response.code}).")
          end
          return :saved
        else
          # for any other response type when --all is true, treat as an error to be retried or failed
          raise "Unhandled HTTP response: #{response.code} #{response.message}"
        end
      else # not @all (our default behavior)
        case response
        when Net::HTTPSuccess
          save_response_body.call
          return :saved
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
          return :skipped_not_found
        else
          raise "HTTP Error: #{response.code} #{response.message}"
        end
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
