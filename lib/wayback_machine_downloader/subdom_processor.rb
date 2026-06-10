# frozen_string_literal: true

module SubdomainProcessor
  def process_subdomains
    return unless @recursive_subdomains
    
    puts "Starting subdomain processing..."
    
    # extract base domain from the URL for comparison
    base_domain = extract_base_domain(@base_url)
    @processed_domains = Set.new([base_domain])
    @subdomain_queue = Queue.new
    
    # scan downloaded files for subdomain links
    initial_files = Dir.glob(File.join(backup_path, "**/*.{html,htm,css,js}"))
    puts "Scanning #{initial_files.size} downloaded files for subdomain links..."
    
    subdomains_found = scan_files_for_subdomains(initial_files, base_domain)
    
    if subdomains_found.empty?
      puts "No subdomains found in downloaded content."
      return
    end
    
    puts "Found #{subdomains_found.size} subdomains to process: #{subdomains_found.join(', ')}"
    
    # add found subdomains to the queue
    subdomains_found.each do |subdomain|
      full_domain = "#{subdomain}.#{base_domain}"
      @subdomain_queue << "https://#{full_domain}/"
    end
    
    # process the subdomain queue
    download_subdomains(base_domain)
    
    # after all downloads, rewrite all URLs to make local references
    rewrite_subdomain_links(base_domain) if @rewrite
  end
  
  private
  
  def extract_base_domain(url)
    # ensure the URL has a scheme for URI parsing
    normalized_url = url.match?(/^https?:\/\//i) ? url : "http://#{url}"
    uri = URI.parse(normalized_url) rescue nil
    return nil unless uri
    
    # extract the host (and default to parsing path if host is missing)
    host = uri.host || (uri.path || '').split('/').first
    return nil unless host
    
    # strip port numbers if present
    host = host.split(':').first.downcase
    
    # extract the base domain (e.g., "example.com" from "sub.example.com")
    parts = host.split('.')
    return host if parts.size <= 2
    
    # for domains like co.uk, we want to keep the last 3 parts
    if parts[-2].length <= 3 && parts[-1].length <= 3 && parts.size > 2
      parts.last(3).join('.')
    else
      parts.last(2).join('.')
    end
  end
  
  def scan_files_for_subdomains(files, base_domain)
    return [] unless base_domain
    
    subdomains = Set.new
    
    files.each do |file_path|
      next unless File.exist?(file_path)
      
      begin
        content = File.read(file_path)
        
        # extract URLs from HTML href/src attributes
        content.scan(/(?:href|src|action|data-src)=["']https?:\/\/([^\/."']+)\.#{Regexp.escape(base_domain)}[\/"]/) do |match|
          subdomain = match[0].downcase
          next if subdomain == 'www' # skip www subdomain
          subdomains.add(subdomain)
        end
        
        # extract URLs from CSS
        content.scan(/url\(["']?https?:\/\/([^\/."']+)\.#{Regexp.escape(base_domain)}[\/"]/) do |match|
          subdomain = match[0].downcase
          next if subdomain == 'www' # skip www subdomain
          subdomains.add(subdomain)
        end
        
        # extract URLs from JavaScript strings
        content.scan(/["']https?:\/\/([^\/."']+)\.#{Regexp.escape(base_domain)}[\/"]/) do |match|
          subdomain = match[0].downcase
          next if subdomain == 'www' # skip www subdomain
          subdomains.add(subdomain)
        end
      rescue => e
        puts "Error scanning file #{file_path}: #{e.message}"
      end
    end
    
    subdomains.to_a
  end
  
  def download_subdomains(base_domain)
    puts "Starting subdomain downloads..."
    depth = 0
    max_depth = @subdomain_depth || 1
    
    while depth < max_depth && !@subdomain_queue.empty?
      current_batch = []
      
      # get all subdomains at current depth
      while !@subdomain_queue.empty?
        current_batch << @subdomain_queue.pop
      end
      
      puts "Processing #{current_batch.size} subdomains at depth #{depth + 1}..."
      
      # download each subdomain
      current_batch.each do |subdomain_url|
        download_subdomain(subdomain_url, base_domain)
      end
      
      # if we need to go deeper, scan the newly downloaded files
      if depth + 1 < max_depth
        # get all files in the subdomains directory
        new_files = Dir.glob(File.join(backup_path, "subdomains", "**/*.{html,htm,css,js}"))
        new_subdomains = scan_files_for_subdomains(new_files, base_domain)
        
        # filter out already processed subdomains
        new_subdomains.each do |subdomain|
          full_domain = "#{subdomain}.#{base_domain}"
          unless @processed_domains.include?(full_domain)
            @processed_domains.add(full_domain)
            @subdomain_queue << "https://#{full_domain}/"
          end
        end
        
        puts "Found #{@subdomain_queue.size} new subdomains at depth #{depth + 1}" if !@subdomain_queue.empty?
      end
      
      depth += 1
    end
  end
  
  def download_subdomain(subdomain_url, base_domain)
    begin
      uri = URI.parse(subdomain_url)
      subdomain_host = uri.host
      
      # skip if already processed
      if @processed_domains.include?(subdomain_host)
        puts "Skipping already processed subdomain: #{subdomain_host}"
        return
      end
      
      @processed_domains.add(subdomain_host)
      puts "Downloading subdomain: #{subdomain_url}"
      
      # create the directory for this subdomain
      subdomain_dir = File.join(backup_path, "subdomains", subdomain_host)
      FileUtils.mkdir_p(subdomain_dir)
      
      # create subdomain downloader with appropriate options
      subdomain_options = {
        base_url: subdomain_url,
        directory: subdomain_dir,
        from_timestamp: @from_timestamp,
        to_timestamp: @to_timestamp,
        all: @all,
        threads_count: @threads_count,
        maximum_pages: [@maximum_pages / 2, 10].max,
        rewrite: @rewrite,
        # don't recursively process subdomains from here
        recursive_subdomains: false
      }
      
      # download the subdomain content
      subdomain_downloader = WaybackMachineDownloader.new(subdomain_options)
      subdomain_downloader.download_files
      
      puts "Completed download of subdomain: #{subdomain_host}"
    rescue => e
      puts "Error downloading subdomain #{subdomain_url}: #{e.message}"
    end
  end
  
  def rewrite_subdomain_links(base_domain)
    puts "Rewriting all files to use local subdomain references..."
    
    all_files = Dir.glob(File.join(backup_path, "**/*.{html,htm,css,js}"))
    subdomains = @processed_domains.reject { |domain| domain == base_domain }
    
    puts "Found #{all_files.size} files to check for rewriting"
    puts "Will rewrite links for subdomains: #{subdomains.join(', ')}"
    
    rewritten_count = 0
    
    all_files.each do |file_path|
      next unless File.exist?(file_path)
      
      begin
        content = File.read(file_path)
        original_content = content.dup
        
        # replace subdomain URLs with local paths
        subdomains.each do |subdomain_host|
          # for HTML attributes (href, src, etc.)
          content.gsub!(/(\s(?:href|src|action|data-src|data-url)=["'])https?:\/\/#{Regexp.escape(subdomain_host)}([^"']*)(["'])/i) do
            prefix, path, suffix = $1, $2, $3
            path = "/index.html" if path.empty? || path == "/"
            "#{prefix}../subdomains/#{subdomain_host}#{path}#{suffix}"
          end
          
          # for CSS url()
          content.gsub!(/url\(\s*["']?https?:\/\/#{Regexp.escape(subdomain_host)}([^"'\)]*?)["']?\s*\)/i) do
            path = $1
            path = "/index.html" if path.empty? || path == "/"
            "url(\"../subdomains/#{subdomain_host}#{path}\")"
          end
          
          # for JavaScript strings
          content.gsub!(/(["'])https?:\/\/#{Regexp.escape(subdomain_host)}([^"']*)(["'])/i) do
            quote_start, path, quote_end = $1, $2, $3
            path = "/index.html" if path.empty? || path == "/"
            "#{quote_start}../subdomains/#{subdomain_host}#{path}#{quote_end}"
          end
        end
        
        # save if modified
        if content != original_content
          File.write(file_path, content)
          rewritten_count += 1
        end
      rescue => e
        puts "Error rewriting file #{file_path}: #{e.message}"
      end
    end
    
    puts "Rewrote links in #{rewritten_count} files"
  end
end