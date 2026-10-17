require 'minitest/autorun'
require_relative '../lib/wayback_machine_downloader'

class PageRequisitesTest < Minitest::Test
  def test_html_entities_in_asset_urls_are_decoded
    html = '<img src="https://cdn.example.com/logo.png?width=132&amp;height=70">'

    assets = PageRequisites.extract(html)

    assert_equal ['https://cdn.example.com/logo.png?width=132&height=70'], assets
  end

  def test_numeric_entities_in_asset_urls_are_decoded
    html = '<link rel="stylesheet" href="https&#x3A;&#x2F;&#x2F;cdn.example.com&#x2F;styles.css&#x3F;bust&#x3D;1">'

    assets = PageRequisites.extract(html)

    assert_equal ['https://cdn.example.com/styles.css?bust=1'], assets
  end

  def test_entities_in_srcset_are_decoded
    html = '<img srcset="a.jpg?w=1&amp;h=1 1x, a.jpg?w=2&amp;h=2 2x">'

    assets = PageRequisites.extract(html)

    assert_equal ['a.jpg?w=1&h=1', 'a.jpg?w=2&h=2'], assets
  end
end
