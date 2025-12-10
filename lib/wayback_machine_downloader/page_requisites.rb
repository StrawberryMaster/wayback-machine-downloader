module PageRequisites
  # regex to find links in href, src, url(), and srcset
  # this ignores data: URIs, mailto:, and anchors
  ASSET_REGEX = /(?:href|src|data-src|data-url)\s*=\s*["']([^"']+)["']|url\(\s*["']?([^"'\)]+)["']?\s*\)|srcset\s*=\s*["']([^"']+)["']/i

  def self.extract(html_content)
    assets = []
    
    html_content.scan(ASSET_REGEX) do |match|
      # match is an array of capture groups; find the one that matched
      url = match.compact.first
      next unless url
      
      # handle srcset (e.g. comma separated values like "image.jpg 1x, image2.jpg 2x")
      if url.include?(',') && (url.include?(' 1x') || url.include?(' 2w'))
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

  def self.valid_asset?(url)
    return false if url.strip.empty?
    return false if url.start_with?('data:', 'mailto:', '#', 'javascript:')
    true
  end
end