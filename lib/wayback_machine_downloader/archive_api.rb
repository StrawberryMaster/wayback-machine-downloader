require 'json'
require 'uri'
require 'time'
require 'thread'

module ArchiveAPI
  DEFAULT_RATE_LIMIT_COOLDOWN = 30.0

  class RateLimitError < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after = nil)
      super(message)
      @retry_after = retry_after
    end
  end

  @cdx_rate_limit_mutex = Mutex.new
  @cdx_rate_limit_until = Time.at(0)

  class << self
    def wait_for_cdx_cooldown
      wait = @cdx_rate_limit_mutex.synchronize do
        [@cdx_rate_limit_until - Time.now, 0].max
      end
      sleep(wait) if wait.positive?
    end

    def extend_cdx_cooldown(seconds)
      seconds = seconds.to_f
      return if seconds <= 0

      @cdx_rate_limit_mutex.synchronize do
        candidate = Time.now + seconds
        @cdx_rate_limit_until = candidate if candidate > @cdx_rate_limit_until
      end
    end

    def reset_cdx_cooldown
      @cdx_rate_limit_mutex.synchronize do
        @cdx_rate_limit_until = Time.at(0)
      end
    end
  end

  def get_raw_list_from_api(url, page_index, http)
    # Automatically append /* for host-only URLs
    # This is a workaround for an issue with the API and *some* domains.
    # See https://github.com/StrawberryMaster/wayback-machine-downloader/issues/6
    # But don't do this when exact_url flag is set, and never append twice
    normalized_url = url.to_s.strip
    
    # strip protocol for CDX query
    clean_url = normalized_url.sub(%r{\Ahttps?://}i, '')
    
    # ensure wildcard/matchType for domain-wide crawling
    match_type = nil
    unless @exact_url || clean_url.include?('*')
      if clean_url.end_with?('/')
        clean_url = "#{clean_url}*"
      elsif !clean_url.include?('/')
        match_type = "prefix"
      else
        clean_url = "#{clean_url}/*"
      end
    end

    request_url = URI("https://web.archive.org/cdx/search/cdx")
    params = [["output", "json"], ["url", clean_url]] + parameters_for_api(page_index)
    params << ["matchType", match_type] if match_type
    request_url.query = URI.encode_www_form(params)

    retries = 0
    max_retries = (@max_retries || 3)
    base_delay = WaybackMachineDownloader::RETRY_DELAY rescue 2

    begin
      # A 429 from any CDX request pauses every worker using this process. Without
      # this shared gate, one worker backs off while the others continue to hit
      # the API and prolong the rate limit.
      ArchiveAPI.wait_for_cdx_cooldown

      if HTTPX_AVAILABLE && http.is_a?(HTTPX::Session)
        response = http.get(request_url)
        raise response.error if response.is_a?(HTTPX::ErrorResponse)

        code = response.status
        body = response.body.to_s.strip
      else
        request = Net::HTTP::Get.new(request_url)
        request["User-Agent"] = "wmd-straw/#{WaybackMachineDownloader::VERSION rescue '2.4.8'}"
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
      when 400
        # CDX API occasionally returns 400 when page index exceeds total available pages (that is, end of pagination)
        return []
      when 429
        retry_after = retry_after_seconds(response)
        raise RateLimitError.new(
          "Server error 429: #{response.respond_to?(:message) ? response.message : 'Too Many Requests'}",
          retry_after
        )
      when 500, 502, 503, 504
        raise "Server error #{code}: #{response.respond_to?(:message) ? response.message : ''}"
      else
        raise "Unexpected API response #{code} for #{url}"
      end
    rescue Net::ReadTimeout, Net::OpenTimeout, StandardError => e
      if retries < max_retries
        retries += 1
        jitter = rand(0.0..1.0)

        if e.is_a?(RateLimitError)
          # Prefer the server-provided Retry-After value. When absent, use a
          # conservative process-wide cooldown instead of the short per-request
          # retry delay used for transient 5xx/network errors.
          fallback = [DEFAULT_RATE_LIMIT_COOLDOWN, base_delay * (2 ** (retries - 1))].max
          cooldown = e.retry_after || fallback
          cooldown += jitter unless e.retry_after
          ArchiveAPI.extend_cdx_cooldown(cooldown)

          warn "Wayback CDX API rate limited (429) for #{url}. " \
               "Pausing all CDX requests for #{cooldown.round(2)}s " \
               "(attempt #{retries}/#{max_retries})..."
        else
          sleep_time = (base_delay * (2 ** (retries - 1))) + jitter

          warn "Error talking to Wayback CDX API (#{e.class}: #{e.message}) for #{url}. " \
               "Retrying in #{sleep_time.round(2)}s (attempt #{retries}/#{max_retries})..."

          sleep(sleep_time)
        end

        retry
      else
        warn "Giving up on Wayback CDX API for #{url} after #{max_retries} attempts. (Last error: #{e.message})"
        # Do not turn transport/API failures into an empty result. Callers use
        # [] as an end-of-pagination signal and may otherwise persist an
        # incomplete .cdx.json cache as if it were complete.
        raise
      end
    end
  end

  def parameters_for_api(page_index)
    parameters = [["fl", "timestamp,original"], ["gzip", "true"]]
    parameters.push(["collapse", "digest"]) unless @keep_duplicates || @all_timestamps
    parameters.push(["filter", "statuscode:2..|30[12378]"]) unless @all
    parameters.push(["from", @from_timestamp.to_s]) if @from_timestamp && @from_timestamp != 0
    parameters.push(["to", @to_timestamp.to_s]) if @to_timestamp && @to_timestamp != 0
    parameters.push(["page", page_index.to_s]) if page_index && page_index > 0
    parameters
  end

  private

  def retry_after_seconds(response)
    raw = if HTTPX_AVAILABLE && defined?(HTTPX::Response) && response.is_a?(HTTPX::Response)
            response.headers['retry-after']
          elsif response.respond_to?(:[])
            response['Retry-After'] || response['retry-after']
          end

    value = Array(raw).first.to_s.strip
    return nil if value.empty?
    return value.to_f if value.match?(/\A\d+(?:\.\d+)?\z/)

    delay = Time.httpdate(value) - Time.now
    delay.positive? ? delay : 0.0
  rescue ArgumentError
    nil
  end

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
