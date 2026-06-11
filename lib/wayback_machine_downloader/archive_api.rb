require 'json'
require 'uri'

module ArchiveAPI

  def get_raw_list_from_api(url, page_index, http)
    # Automatically append /* for host-only URLs
    # This is a workaround for an issue with the API and *some* domains.
    # See https://github.com/StrawberryMaster/wayback-machine-downloader/issues/6
    # But don't do this when exact_url flag is set, and never append twice
    match_type = nil
    if url && !@exact_url
      normalized_url = url.to_s
      has_wildcard = normalized_url.include?('*')
      host_and_rest = normalized_url
        .sub(/\Ahttps?:\/\//i, '')
        .split(/[?#]/, 2)
        .first
      has_path = host_and_rest.include?('/')

      unless has_wildcard || has_path
        match_type = "prefix"
      end
    end

    request_url = URI("https://web.archive.org/cdx/search/cdx")
    params = [["output", "json"], ["url", url]] + parameters_for_api(page_index)
    params << ["matchType", match_type] if match_type
    request_url.query = URI.encode_www_form(params)

    retries = 0
    max_retries = (@max_retries || 3)
    base_delay = WaybackMachineDownloader::RETRY_DELAY rescue 2

    begin
      if HTTPX_AVAILABLE && http.is_a?(HTTPX::Session)
        response = http.get(request_url)
        raise response.error if response.is_a?(HTTPX::ErrorResponse)
        
        code = response.status
        body = response.body.to_s.strip
      else
        request = Net::HTTP::Get.new(request_url)
        request["User-Agent"] = "wmd-straw/#{WaybackMachineDownloader::VERSION rescue '2.4.7'}"
        request["Connection"] = "keep-alive"
        request["Accept-Encoding"] = "gzip, deflate"
        response = http.request(request)
        code = response.code.to_i
        body = decompress_body(response)
      end

      case code
      when 200
        return [] if body.empty?
        begin
          json = JSON.parse(body)
          # check if the response contains the header ["timestamp", "original"]
          json.shift if json.first == ["timestamp", "original"]
          json
        rescue JSON::ParserError => e
          raise "Malformed JSON response: #{e.message}"
        end
      when 429, 500, 502, 503, 504
        raise "Server error #{code}: #{response.respond_to?(:message) ? response.message : ''}"
      else
        warn "Unexpected API response #{code} for #{url}"
        []
      end
    rescue Net::ReadTimeout, Net::OpenTimeout, StandardError => e
      if retries < max_retries
        retries += 1
        
        jitter = rand(0.0..1.0)
        sleep_time = (base_delay * (2 ** (retries - 1))) + jitter
        
        warn "Error talking to Wayback CDX API (#{e.class}: #{e.message}) for #{url}. " \
             "Retrying in #{sleep_time.round(2)}s (attempt #{retries}/#{max_retries})..."
             
        sleep(sleep_time)
        retry
      else
        warn "Giving up on Wayback CDX API for #{url} after #{max_retries} attempts. (Last error: #{e.message})"
        []
      end
    end
  end

  def parameters_for_api(page_index)
    parameters = [["fl", "timestamp,original"], ["gzip", "true"]]
    parameters.push(["collapse", "digest"]) unless @keep_duplicates || @all_timestamps
    parameters.push(["filter", "statuscode:2..|30[12378]"]) unless @all
    parameters.push(["from", @from_timestamp.to_s]) if @from_timestamp && @from_timestamp != 0
    parameters.push(["to", @to_timestamp.to_s]) if @to_timestamp && @to_timestamp != 0
    parameters.push(["page", page_index]) if page_index
    parameters
  end

  private

  def decompress_body(response)
    body = response.body.to_s
    return body if body.empty?

    case response['content-encoding']
    when 'gzip'
      Zlib::GzipReader.new(StringIO.new(body)).read rescue body
    when 'deflate'
      Zlib::Inflate.inflate(body) rescue body
    else
      body.strip
    end
  end
end