require 'minitest/autorun'
require_relative '../lib/wayback_machine_downloader'

class FakeCDXResponse
  attr_reader :code, :body, :message

  def initialize(code:, body: '', message: '', headers: {})
    @code = code.to_s
    @body = body
    @message = message
    @headers = headers.transform_keys { |key| key.to_s.downcase }
  end

  def [](key)
    @headers[key.to_s.downcase]
  end
end

class FakeCDXConnection
  attr_reader :requests

  def initialize(responses)
    @responses = responses.dup
    @requests = 0
  end

  def request(_request)
    @requests += 1
    @responses.shift
  end
end

class CDXRateLimitTest < Minitest::Test
  def setup
    ArchiveAPI.reset_cdx_cooldown
    @downloader = WaybackMachineDownloader.new(
      base_url: 'https://www.example.com',
      max_retries: 1
    )
  end

  def teardown
    ArchiveAPI.reset_cdx_cooldown
    FileUtils.rm_rf(@downloader.backup_path)
  end

  def test_429_uses_retry_after_and_retries_successfully
    rate_limited = FakeCDXResponse.new(
      code: 429,
      message: 'Too Many Requests',
      headers: { 'Retry-After' => '7' }
    )
    success = FakeCDXResponse.new(
      code: 200,
      body: '[["timestamp","original"],["20200101000000","https://www.example.com/"]]'
    )
    connection = FakeCDXConnection.new([rate_limited, success])
    cooldowns = []

    ArchiveAPI.stub(:wait_for_cdx_cooldown, nil) do
      ArchiveAPI.stub(:extend_cdx_cooldown, ->(seconds) { cooldowns << seconds }) do
        result = @downloader.get_raw_list_from_api('https://www.example.com', 0, connection)

        assert_equal [['20200101000000', 'https://www.example.com/']], result
      end
    end

    assert_equal [7.0], cooldowns
    assert_equal 2, connection.requests
  end

  def test_api_failure_is_not_converted_to_empty_result
    @downloader.instance_variable_set(:@max_retries, 0)
    connection = FakeCDXConnection.new([
      FakeCDXResponse.new(code: 503, message: 'Service Unavailable')
    ])

    error = assert_raises(RuntimeError) do
      @downloader.get_raw_list_from_api('https://www.example.com', 0, connection)
    end

    assert_match(/Server error 503/, error.message)
  end

  def test_php3_navigation_link_is_not_a_page_requisite
    html = <<~HTML
      <a href="announcement-raids.php3">announcement</a>
      <link href="styles/site.css" rel="stylesheet">
      <img src="images/logo.gif">
    HTML

    assets = PageRequisites.extract(html)

    refute_includes assets, 'announcement-raids.php3'
    assert_includes assets, 'styles/site.css'
    assert_includes assets, 'images/logo.gif'
  end

  def test_dynamic_src_is_still_allowed_as_a_requisite
    assets = PageRequisites.extract('<script src="asset.php3"></script>')

    assert_includes assets, 'asset.php3'
  end
end
