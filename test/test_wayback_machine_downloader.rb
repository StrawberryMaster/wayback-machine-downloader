require 'minitest/autorun'
require_relative '../lib/wayback_machine_downloader'
require 'tmpdir'

class SequenceConnection
  attr_reader :paths

  def initialize(responses)
    @responses = responses.dup
    @paths = []
  end

  def request(request)
    @paths << request.path
    @responses.shift
  end
end

class TestHTTPOkResponse < Net::HTTPOK
  def initialize(body)
    super('1.1', '200', 'OK')
    @test_body = body
  end

  def body
    @test_body
  end
end

class WaybackMachineDownloaderTest < Minitest::Test

  def setup
    @wayback_machine_downloader = WaybackMachineDownloader.new(
      base_url: 'https://www.example.com'
    )
    @wayback_machine_downloader.instance_variable_set(:@logger, Logger.new(nil))
    $stdout = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@wayback_machine_downloader.backup_path)
  end

  def test_base_url_being_set
    assert_equal 'https://www.example.com', @wayback_machine_downloader.base_url
  end

  def test_backup_name_being_set
    assert_equal 'www.example.com', @wayback_machine_downloader.backup_name
  end

  def test_backup_name_being_set_when_base_url_is_domain
    @wayback_machine_downloader.base_url = 'www.example.com'
    assert_equal 'www.example.com', @wayback_machine_downloader.backup_name
  end

  def test_file_list_curated
    assert_equal 20060711191226, @wayback_machine_downloader.get_file_list_curated["linux.htm"][:timestamp]
  end

  def test_parameters_include_redirect_statuses_by_default
    filter = @wayback_machine_downloader.send(:parameters_for_api, 0).find { |key, _| key == 'filter' }
    assert_equal 'statuscode:2..|30[12378]', filter.last
  end

  def test_redirect_source_resolution
    assert_equal 'http://www.example.com/new-path',
      @wayback_machine_downloader.send(:resolve_redirect_source, 'http://www.example.com/index.php', '/new-path')

    archived_url = 'https://web.archive.org/web/20200101000000id_/http://www.example.com/new-path'
    assert_equal archived_url,
      @wayback_machine_downloader.send(:resolve_redirect_source, 'http://www.example.com/index.php', archived_url)
  end

  def test_download_with_retry_follows_relative_redirects
    tempdir = Dir.mktmpdir
    @wayback_machine_downloader = WaybackMachineDownloader.new(
      base_url: 'https://www.example.com',
      directory: tempdir
    )
    @wayback_machine_downloader.instance_variable_set(:@logger, Logger.new(nil))

    redirect_response = Net::HTTPFound.new('1.1', '302', 'Found')
    redirect_response['location'] = '/new-path'

    success_response = TestHTTPOkResponse.new('redirected content')

    connection = SequenceConnection.new([redirect_response, success_response])
    file_path = File.join(tempdir, 'redirect-test.html')

    result = @wayback_machine_downloader.send(
      :download_with_retry,
      file_path,
      'http://www.example.com/index.php',
      20200101000000,
      connection
    )

    assert_equal :saved, result
    assert_equal 2, connection.paths.length
    assert_includes connection.paths[0], '/web/20200101000000id_/http://www.example.com/index.php'
    assert_includes connection.paths[1], '/web/20200101000000id_/http://www.example.com/new-path'
    assert File.exist?(file_path)
    assert_equal 'redirected content', File.read(file_path)
  ensure
    FileUtils.rm_rf(tempdir)
  end

  def test_file_list_by_timestamp
    file_expected = {
      file_url: "http://www.onlyfreegames.net:80/strat.html",
      timestamp: 20060111084756,
      file_id: "strat.html"
    }
    assert_equal file_expected, @wayback_machine_downloader.get_file_list_by_timestamp[-2]
  end

  def test_without_exact_url
    @wayback_machine_downloader.exact_url = false
    assert @wayback_machine_downloader.get_file_list_curated.size > 1
  end

  def test_exact_url
    @wayback_machine_downloader.exact_url = true
    assert_equal 1, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_file_list_only_filter_without_matches
    @wayback_machine_downloader.only_filter = 'abc123'
    assert_equal 0, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_file_list_only_filter_with_1_match
    @wayback_machine_downloader.only_filter = 'menu.html'
    assert_equal 1, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_file_list_only_filter_with_a_regex
    @wayback_machine_downloader.only_filter = '/\.(gif|je?pg|bmp)$/i'
    assert_equal 37, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_file_list_exclude_filter_without_matches
    @wayback_machine_downloader.exclude_filter = 'abc123'
    assert_equal 68, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_file_list_exclude_filter_with_1_match
    @wayback_machine_downloader.exclude_filter = 'menu.html'
    assert_equal 67, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_file_list_exclude_filter_with_a_regex
    @wayback_machine_downloader.exclude_filter = '/\.(gif|je?pg|bmp)$/i'
    assert_equal 31, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_file_download
    @wayback_machine_downloader.download_files
    linux_page = open 'websites/www.onlyfreegames.net/linux.htm'
    assert_includes linux_page.read, "Linux Games"
  end

  def test_all_timestamps_being_respected
    @wayback_machine_downloader.all_timestamps = true
    assert_equal 68, @wayback_machine_downloader.get_file_list_curated.size
  end

  def test_from_timestamp_being_respected
    @wayback_machine_downloader.from_timestamp = 20050716231334
    file_url = @wayback_machine_downloader.get_file_list_curated["linux.htm"][:file_url]
    assert_equal "http://www.onlyfreegames.net:80/linux.htm", file_url
  end

  def test_to_timestamp_being_respected
    @wayback_machine_downloader.to_timestamp = 20050716231334
    assert_nil @wayback_machine_downloader.get_file_list_curated["linux.htm"]
  end

  def test_all_get_file_list_curated_size
    @wayback_machine_downloader.all = true
    assert_equal 69, @wayback_machine_downloader.get_file_list_curated.size
  end

  # Testing encoding conflicts needs a different base_url
  def test_nonascii_suburls_download
    @wayback_machine_downloader = WaybackMachineDownloader.new(
      base_url: 'https://en.wikipedia.org/wiki/%C3%84')
    # Once just for the downloading...
    @wayback_machine_downloader.download_files
  end

  def test_nonascii_suburls_already_present
    @wayback_machine_downloader = WaybackMachineDownloader.new(
      base_url: 'https://en.wikipedia.org/wiki/%C3%84')
    # ... twice to test the "is already present" case
    @wayback_machine_downloader.download_files
    @wayback_machine_downloader.download_files
  end

end
