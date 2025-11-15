require 'json'
require 'uri'

module ArchiveAPI

  def get_raw_list_from_api(url, page_index, http)
    # Automatically append /* if the URL doesn't contain a path after the domain
    # This is a workaround for an issue with the API and *some* domains.
    # See https://github.com/StrawberryMaster/wayback-machine-downloader/issues/6
    # But don't do this when exact_url flag is set
    if url && !url.match(/^https?:\/\/.*\//i) && !@exact_url
      url = "#{url}/*"
    end

    request_url = URI("https://web.archive.org/cdx/search/cdx")
    params = [["output", "json"], ["url", url]] + parameters_for_api(page_index)
    request_url.query = URI.encode_www_form(params)

    retries = 0
    max_retries = (@max_retries || 3)
    delay = WaybackMachineDownloader::RETRY_DELAY rescue 2

    begin
      response = http.get(request_url)
      body = response.body.to_s.strip
      return [] if body.empty?
      json = JSON.parse(body)

      # Check if the response contains the header ["timestamp", "original"]
      json.shift if json.first == ["timestamp", "original"]
      json
    rescue JSON::ParserError => e
      warn "Failed to parse JSON from API for #{url}: #{e.message}"
      []
    rescue Net::ReadTimeout, Net::OpenTimeout => e
      if retries < max_retries
        retries += 1
        warn "Timeout talking to Wayback CDX API (#{e.class}: #{e.message}) for #{url}, retry #{retries}/#{max_retries}..."
        sleep(delay * retries)
        retry
      else
        warn "Giving up on Wayback CDX API for #{url} after #{max_retries} timeouts."
        []
      end
    rescue StandardError => e
      # treat any other transient-ish error similarly, though without retries for now
      warn "Error fetching CDX data for #{url}: #{e.message}"
      []
    end
  end

  def parameters_for_api(page_index)
    parameters = [["fl", "timestamp,original"], ["collapse", "digest"], ["gzip", "false"]]
    parameters.push(["filter", "statuscode:200"]) unless @all
    parameters.push(["from", @from_timestamp.to_s]) if @from_timestamp && @from_timestamp != 0
    parameters.push(["to", @to_timestamp.to_s]) if @to_timestamp && @to_timestamp != 0
    parameters.push(["page", page_index]) if page_index
    parameters
  end

end
