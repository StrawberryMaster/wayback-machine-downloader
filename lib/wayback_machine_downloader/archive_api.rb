require 'json'
require 'uri'
require 'time'
require 'thread'

module ArchiveAPI
  DEFAULT_RATE_LIMIT_COOLDOWN = 30.0
  DEFAULT_CDX_INTERVAL = 2.5 # 1 request every 2.5 seconds

  class RateLimitError < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after = nil)
      super(message)
      @retry_after = retry_after
    end
  end

  @cdx_mutex = Mutex.new
  @cdx_cv = ConditionVariable.new
  @next_allowed_cdx_at = 0.0
  @cdx_interval = DEFAULT_CDX_INTERVAL

  class << self
    attr_accessor :cdx_interval

    # pace CDX requests to avoid exceeding the rate limit
    def pace_cdx_request
      @cdx_mutex.synchronize do
        loop do
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if now < @next_allowed_cdx_at
            wait_time = @next_allowed_cdx_at - now
            @cdx_cv.wait(@cdx_mutex, wait_time)
          else
            interval = @cdx_interval || DEFAULT_CDX_INTERVAL
            @next_allowed_cdx_at = now + interval
            return
          end
        end
      end
    end

    # extend the cooldown period for CDX requests, e.g., after receiving a 429 response
    def extend_cdx_cooldown(seconds)
      seconds = seconds.to_f
      return if seconds <= 0

      @cdx_mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        candidate = now + seconds
        @next_allowed_cdx_at = candidate if candidate > @next_allowed_cdx_at
        @cdx_cv.broadcast
      end
    end

    def reset_cdx_limiter
      @cdx_mutex.synchronize do
        @next_allowed_cdx_at = 0.0
        @cdx_cv.broadcast
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
    base_delay = 2

    begin
      # acquire slot from the process-wide proactive pacer before sending request
      ArchiveAPI.pace_cdx_request

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
          # if the server provided a Retry-After header, use that; otherwise, use an exponential backoff with a minimum cooldown
          fallback = [DEFAULT_RATE_LIMIT_COOLDOWN, base_delay * (2 ** (retries - 1))].max
          cooldown = (e.retry_after || fallback) + (e.retry_after ? 0 : jitter)
          ArchiveAPI.extend_cdx_cooldown(cooldown)

          warn "Wayback CDX API rate limited (429) for #{url}. " \
               "Pausing CDX requests for #{cooldown.round(2)}s " \
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