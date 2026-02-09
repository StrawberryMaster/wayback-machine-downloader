Gem::Specification.new do |s|
  s.name        = "wayback_machine_downloader_straw"
  s.version     = "2.4.6"
  s.executables << "wayback_machine_downloader"
  s.summary     = "Download an entire website from the Wayback Machine."
  s.description = "Download complete websites from the Internet Archive's Wayback Machine. While the Wayback Machine (archive.org) excellently preserves web history, it lacks a built-in export functionality; this gem does just that, allowing you to download entire archived websites. (This is a significant rewrite of the original wayback_machine_downloader gem by hartator, with enhanced features and performance improvements.)"
  s.authors     = ["strawberrymaster"]
  s.email       = "strawberrymaster@vivaldi.net"
  s.files       = ["lib/wayback_machine_downloader.rb", "lib/wayback_machine_downloader/tidy_bytes.rb", "lib/wayback_machine_downloader/to_regex.rb", "lib/wayback_machine_downloader/archive_api.rb", "lib/wayback_machine_downloader/page_requisites.rb", "lib/wayback_machine_downloader/subdom_processor.rb", "lib/wayback_machine_downloader/url_rewrite.rb"]
  s.homepage    = "https://github.com/StrawberryMaster/wayback-machine-downloader"
  s.license     = "MIT"
  s.required_ruby_version = ">= 3.4.3"
  s.add_runtime_dependency "concurrent-ruby", "~> 1.3", ">= 1.3.4"
  s.add_development_dependency "rake", "~> 12.2"
  s.add_development_dependency "minitest", "~> 5.2"
end
