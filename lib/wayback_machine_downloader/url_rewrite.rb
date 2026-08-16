# frozen_string_literal: true

module URLRewrite
  # server-side extensions that should work locally
  SERVER_SIDE_EXTS = %w[
    .php .php3 .phtml 
    .asp .aspx .ashx .asmx .asa 
    .jsp .jspx .do .action 
    .cgi .pl .py .cfm .shtml
  ].freeze

  def rewrite_html_attr_urls(content, root_prefix = './')
    target_host = current_host

    # rewrite URLs to relative paths
    content = content.gsub(/(\s(?:href|src|action|data-src|data-url)=["'])https?:\/\/web\.archive\.org\/web\/\d+[a-z_]*\/https?:\/\/[^\/"']+(\/[^"']*)?(["'])/i) do
      prefix, path, suffix = $1, ($2 || "/index.html"), $3
      local = normalize_path_for_local(path, root_prefix)
      "#{prefix}#{local}#{suffix}"
    end

    # rewrite absolute URLs to same domain as relative
    if target_host && !target_host.empty?
      content = content.gsub(/(\s(?:href|src|action|data-src|data-url)=["'])https?:\/\/#{Regexp.escape(target_host)}(?::\d+)?(\/[^"']*)?(["'])/i) do
        prefix, path, suffix = $1, ($2 || "/index.html"), $3
        local = normalize_path_for_local(path, root_prefix)
        "#{prefix}#{local}#{suffix}"
      end
    end

    # rewrite root-relative URLs
    content = content.gsub(/(\s(?:href|src|action|data-src|data-url)=["'])\/([^"'\/][^"']*)(["'])/i) do
      prefix, path, suffix = $1, $2, $3
      local = normalize_path_for_local("/#{path}", root_prefix)
      "#{prefix}#{local}#{suffix}"
    end

    content
  end

  def rewrite_css_urls(content, root_prefix = './')
    target_host = current_host

    # rewrite URLs in CSS
    content = content.gsub(/url\(\s*["']?https?:\/\/web\.archive\.org\/web\/\d+[a-z_]*\/https?:\/\/[^\/"'\)]+(\/[^"'\)]*)?["']?\s*\)/i) do
      path = $1 || "/index.html"
      local = normalize_path_for_local(path, root_prefix)
      "url(\"#{local}\")"
    end

    # rewrite absolute URLs in CSS
    if target_host && !target_host.empty?
      content = content.gsub(/url\(\s*["']?https?:\/\/#{Regexp.escape(target_host)}(?::\d+)?(\/[^"'\)]*)?["']?\s*\)/i) do
        path = $1 || "/index.html"
        local = normalize_path_for_local(path, root_prefix)
        "url(\"#{local}\")"
      end
    end

    # rewrite root-relative in CSS
    content = content.gsub(/url\(\s*["']?\/([^"'\)\/][^"'\)]*?)["']?\s*\)/i) do
      path = $1
      local = normalize_path_for_local("/#{path}", root_prefix)
      "url(\"#{local}\")"
    end

    content
  end

  def rewrite_js_urls(content, root_prefix = './')
    # rewrite archive.org URLs in JavaScript strings
    content.gsub(/(["'])https?:\/\/web\.archive\.org\/web\/\d+[a-z_]*\/https?:\/\/[^\/"']+(\/[^"']*)?(["'])/i) do
      quote_start, path, quote_end = $1, ($2 || "/index.html"), $3
      local = normalize_path_for_local(path, root_prefix)
      "#{quote_start}#{local}#{quote_end}"
    end
  end

  def normalize_path_for_local(path, root_prefix = './')
    path = path.to_s.strip
    return "#{root_prefix}index.html" if path.empty? || path == "/"

    path_part, query_part = path.split('?', 2)
    path_part = "/index.html" if path_part.nil? || path_part.empty? || path_part == "/"

    # hash query parameters to match sanitize_and_prepare_id
    if query_part && !query_part.empty?
      q_digest = Digest::SHA256.hexdigest(query_part)[0, 12]
      if path_part.include?('.')
        pre, _sep, post = path_part.rpartition('.')
        path_part = "#{pre}__q#{q_digest}.#{post}"
      else
        path_part = "#{path_part}__q#{q_digest}"
      end
    end

    # check if this is a server-side script
    ext = File.extname(path_part).downcase
    unless SERVER_SIDE_EXTS.include?(ext)
      if path_part.end_with?('/') || !path_part.include?('.')
        path_part = "#{path_part.chomp('/')}/index.html"
      end
    end

    clean_path = path_part.sub(%r{\A/+}, '')
    "#{root_prefix}#{clean_path}"
  end

  private

  def current_host
    return nil unless @base_url
    clean = @base_url.to_s.sub(%r{\A\*\.}, '')
    clean = clean.match?(%r{\Ahttps?://}i) ? clean : "http://#{clean}"
    URI.parse(clean).host rescue nil
  end
end