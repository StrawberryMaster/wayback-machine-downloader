# frozen_string_literal: true

module URLRewrite
  # server-side extensions that should work locally
  SERVER_SIDE_EXTS = %w[
    .php .php3 .phtml 
    .asp .aspx .ashx .asmx .asa 
    .jsp .jspx .do .action 
    .cgi .pl .py .cfm .shtml
  ].freeze

  def rewrite_html_attr_urls(content)
    # rewrite URLs to relative paths
    content.gsub!(/(\s(?:href|src|action|data-src|data-url)=["'])https?:\/\/web\.archive\.org\/web\/\d+(?:id_)?\/https?:\/\/[^\/]+([^"']*)(["'])/i) do
      prefix, path, suffix = $1, $2, $3
      path = normalize_path_for_local(path)
      "#{prefix}#{path}#{suffix}"
    end

    # rewrite absolute URLs to same domain as relative
    content.gsub!(/(\s(?:href|src|action|data-src|data-url)=["'])https?:\/\/[^\/]+([^"']*)(["'])/i) do
      prefix, path, suffix = $1, $2, $3
      path = normalize_path_for_local(path)
      "#{prefix}#{path}#{suffix}"
    end

    content
  end

  def rewrite_css_urls(content)
    # rewrite URLs in CSS
    content.gsub!(/url\(\s*["']?https?:\/\/web\.archive\.org\/web\/\d+(?:id_)?\/https?:\/\/[^\/]+([^"'\)]*?)["']?\s*\)/i) do
      path = normalize_path_for_local($1)
      "url(\"#{path}\")"
    end

    # rewrite absolute URLs in CSS
    content.gsub!(/url\(\s*["']?https?:\/\/[^\/]+([^"'\)]*?)["']?\s*\)/i) do
      path = normalize_path_for_local($1)
      "url(\"#{path}\")"
    end

    content
  end

  def rewrite_js_urls(content)
    # rewrite archive.org URLs in JavaScript strings
    content.gsub!(/(["'])https?:\/\/web\.archive\.org\/web\/\d+(?:id_)?\/https?:\/\/[^\/]+([^"']*)(["'])/i) do
      quote_start, path, quote_end = $1, $2, $3
      path = normalize_path_for_local(path)
      "#{quote_start}#{path}#{quote_end}"
    end

    # rewrite absolute URLs in JavaScript
    content.gsub!(/(["'])https?:\/\/[^\/]+([^"']*)(["'])/i) do
      quote_start, path, quote_end = $1, $2, $3
      next "#{quote_start}http#{$2}#{quote_end}" if $2.start_with?('s://', '://')
      path = normalize_path_for_local(path)
      "#{quote_start}#{path}#{quote_end}"
    end

    content
  end

  private

  def normalize_path_for_local(path)
    return "./index.html" if path.empty? || path == "/"

    path_part, query_part = path.split('?', 2)
    if query_part && !query_part.empty?
      q_digest = Digest::SHA256.hexdigest(query_part)[0, 12]
      if path_part.include?('.')
        pre, _sep, post = path_part.rpartition('.')
        path_part = "#{pre}__q#{q_digest}.#{post}"
      else
        path_part = "#{path_part}__q#{q_digest}"
      end
    end
    path = path_part

    # check if this is a server-side script
    ext = File.extname(path).downcase
    if SERVER_SIDE_EXTS.include?(ext)
      # keep the path as-is but ensure it starts with ./
      path = "./#{path}" unless path.start_with?('./', '/')
    else
      # regular file handling
      path = "./#{path}" unless path.start_with?('./', '/')
      
      # if it looks like a directory, add index.html
      if path.end_with?('/') || !path.include?('.')
        path = "#{path.chomp('/')}/index.html"
      end
    end

    path
  end
end
