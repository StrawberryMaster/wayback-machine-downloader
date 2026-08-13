module PageRequisites
  # regex to find links in href, src, url(), and srcset
  # this ignores data: URIs, mailto:, and anchors
  ASSET_REGEX = /(?:(href|src|data-src|data-url)\s*=\s*["']([^"']+)["'])|url\(\s*["']?([^"'\)]+)["']?\s*\)|srcset\s*=\s*["']([^"']+)["']/i
 PAGE_EXTENSIONS = %w[
    .html .htm .shtml .shtm .xhtml
    .asp .aspx .asa .ashx .asmx
    .php .php3 .php4 .php5 .phtml
    .jsp .jspx .do .action
    .cgi .pl .cfm .dll
  ].freeze

  def self.extract(html_content)
    assets = []

    html_content.scan(ASSET_REGEX) do |match|
      attribute, attr_url, css_url, srcset_url = match
      url = attr_url || css_url || srcset_url
      next unless url

      # href is also used for navigation. Do not turn links to server-rendered
      # pages into prerequisite CDX lookups; doing so can multiply API traffic
      # dramatically on old sites that use extensions such as .php3.
      next if attribute&.downcase == 'href' && page_url?(url)

      # handle srcset (e.g. comma separated values like "image.jpg 1x, image2.jpg 2w")
      if srcset_url
        url.split(',').each do |src_def|
          src_url = src_def.strip.split(' ').first
          assets << src_url if valid_asset?(src_url)
        end
      else
        assets << url if valid_asset?(url)
      end
    end

    assets.uniq
  end

  def self.page_url?(url)
    path = begin
      URI.parse(url).path
    rescue URI::InvalidURIError
      url.to_s.split(/[?#]/, 2).first
    end

    ext = File.extname(path.to_s).downcase
    ext.empty? || PAGE_EXTENSIONS.include?(ext)
  end

  def self.valid_asset?(url)
    return false if url.strip.empty?
    return false if url.start_with?('data:', 'mailto:', '#', 'javascript:')
    true
  end
end
