# wmd-straw
[![version](https://badge.fury.io/rb/wayback_machine_downloader_straw.svg)](https://rubygems.org/gems/wayback_machine_downloader_straw)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This is **wmd-straw** (or wayback-machine-downloader-straw), a fork of the [Wayback Machine Downloader](https://github.com/hartator/wayback-machine-downloader). With this, you can download a website from the Internet Archive Wayback Machine.

Included here is partial content from other forks, namely those from [ShiftaDeband](https://github.com/ShiftaDeband/wayback-machine-downloader) and [matthid](https://github.com/matthid/wayback-machine-downloader) — attributions are in the code and go to the original authors — as well as a few additional features.

## Quick start

Download a website's latest snapshot:
```bash
wayback_machine_downloader https://example.com
```
Your files will be saved to `./websites/example.com/` with their original structure preserved.

## Installation

### Requirements
- Ruby 2.3+ ([download Ruby here](https://www.ruby-lang.org/en/downloads/))
- Bundler gem (`gem install bundler`)

### Quick install
It took a while, but we have a gem for this! Install it with:
```bash
gem install wayback_machine_downloader_straw
```
To run most commands, just like in the original WMD, you can use:
```bash
wayback_machine_downloader https://example.com
```
Note that you can also manually download this repository and run commands locally by appending `ruby` before a command (e.g., `ruby wayback_machine_downloader https://example.com`).

**Conflict warning**: This gem may conflict with hartator's original `wayback_machine_downloader` gem. You might need to uninstall the original for this fork to work. A good way to tell is if a command fails and lists the gem version as 2.3.1 or earlier; this WMD fork uses 2.3.2 or above.

### Step-by-step setup
1. **Install Ruby**:
   ```bash
   ruby -v
   ```
   This will verify your installation. If it's not installed, [download Ruby](https://www.ruby-lang.org/en/downloads/) for your OS.

2. **Install dependencies**:
   ```bash
   bundle install
   ```
   If you encounter an error like `cannot load such file -- concurrent-ruby`, manually install the missing gem:
   ```bash
   gem install concurrent-ruby
   ```
   
3. **Run it**:
   ```bash
   cd path/to/wayback-machine-downloader/bin
   ruby wayback_machine_downloader https://example.com
   ```
   For example, if you extracted the contents to a folder named "wayback-machine-downloader" in your Downloads directory, you'd type `cd Downloads\wayback-machine-downloader\bin`.

*Windows tip*: In File Explorer, Shift + Right Click your `bin` folder → "Open Terminal here".

## Docker users
We have a Docker image! See [Packages](https://github.com/StrawberryMaster/wayback-machine-downloader/pkgs/container/wayback-machine-downloader) for the latest version. You can also build it yourself:

```bash
docker build -t wayback_machine_downloader .
docker run -it --rm wayback_machine_downloader [options] URL
```

As an example of how this works without cloning this repo, this command fetches smallrockets.com until the year 2013:

```bash
docker run -v .:/build/websites ghcr.io/strawberrymaster/wayback-machine-downloader:master wayback_machine_downloader --to 20130101 smallrockets.com
```

### Using Docker Compose
You can also use Docker Compose, which makes it easier to extend functionality (such as implementing a database to store previous downloads):

```yaml
# docker-compose.yml
services:
  wayback_machine_downloader:
    build:
        context: .
    tty: true
    image: wayback_machine_downloader:latest
    container_name: wayback_machine_downloader
    volumes:
      - .:/build:rw
      - ./websites:/build/websites:rw
```

#### Usage
Create the image named "wayback_machine_downloader":
```bash
docker compose up -d --build
```

Run the container:
```bash
docker compose run --rm wayback_machine_downloader https://example.com [options]
```

## Configuration
There are a few constants in `wayback_machine_downloader.rb` that can be edited for your convenience. The default values may be conservative, so you can adjust them to your needs:

```ruby
DEFAULT_TIMEOUT = 30        # HTTP timeout (in seconds)
MAX_RETRIES = 3             # Number of times to retry failed requests
RETRY_DELAY = 2             # Wait time between retries (seconds)
RATE_LIMIT = 0.25           # Throttle between requests (seconds)
CONNECTION_POOL_SIZE = 10   # Maximum simultaneous connections
MEMORY_BUFFER_SIZE = 16384  # Download buffer size (bytes)
STATE_CDX_FILENAME = '.cdx.json'       # Stores snapshot listing
STATE_DB_FILENAME = '.downloaded.txt'  # Tracks completed downloads
```

## Advanced usage

### Basic options
| Option | Description |
|--------|-------------|
| `-d DIR`, `--directory DIR` | Custom output directory |
| `-s`, `--all-timestamps`     | Download all historical versions |
| `-f TS`, `--from TS`  | Start from timestamp (e.g., 20060121) |
| `-t TS`, `--to TS`  | Stop at timestamp |
| `-e`, `--exact-url`     | Download exact URL only |
| `-r`, `--rewritten`     | Download rewritten Wayback Archive files only |
| `--rt`, `--retry NUM` | Number of tries in case a download fails (default: 1) |
| `--recursive-subdomains` | Scan downloaded HTML/CSS/JS for subdomains of the base domain and download them too |
| `--subdomain-depth N` | How many discovery rounds to perform when recursively pulling subdomains |
| `--local` | Rewrite HTML/CSS/JS to use local relative links |

**Download to specific directory**
```bash
ruby wayback_machine_downloader https://example.com --directory downloaded-backup/
```
By default, files are downloaded to `./websites/` followed by the domain name. Use this to save files elsewhere.

**Download historical timestamps**
```bash
ruby wayback_machine_downloader https://example.com --all-timestamps 
```
This downloads all snapshots for a website, using the timestamp as the directory name. For example:
```text
websites/example.com/20060715085250/index.html
websites/example.com/20051120005053/index.html
```

**Download content from a specific timeframe**
```bash
# On or after July 16, 2006
ruby wayback_machine_downloader https://example.com --from 20060716231334 

# On or before September 16, 2010
ruby wayback_machine_downloader https://example.com --to 20100916231334
```
Timestamps can be found inside the URLs of the regular Wayback Machine website. You can also use years (2006) or year + month (200607). These flags can be combined to create a range.

**Download exact URL**
```bash
ruby wayback_machine_downloader https://example.com --exact-url
```
Retrieves only the file matching exactly the URL provided, avoiding the rest of the site.

**Download rewritten files**
```bash
ruby wayback_machine_downloader https://example.com --rewritten
```
Useful if you want to download the files exactly as they exist on the Wayback Machine (with their rewriting injected) instead of the original raw files.

**Recursive subdomains with local links**
```bash
ruby wayback_machine_downloader https://example.com --recursive-subdomains --subdomain-depth 1 --local
```
Grabs the site and any discovered subdomains one level deep, rewriting links to work locally.

---

### Page requisites
| Option | Description |
|--------|-------------|
| `--page-requisites` | After an HTML page is saved, enqueue its linked assets (CSS/JS/images) from the same host for download |

**Download pages plus referenced assets**
```bash
wayback_machine_downloader https://example.com --page-requisites
```
Useful if WMD didn't naturally pick up all the content you wanted.

---

### Composite snapshot at a point in time
| Option | Description |
|--------|-------------|
| `--snapshot-at TS` | Build a “best effort” snapshot at timestamp `TS` by picking the newest version of each file at or before `TS` (e.g., `20130101000000`). |

**Freeze the site as of Jan 1, 2013**
```bash
wayback_machine_downloader https://example.com --snapshot-at 20130101000000
```

---

### Filtering content
| Option | Description |
|--------|-------------|
| `-o FILTER`, `--only FILTER` | Only download matching URLs (supports regex) |
| `-x FILTER`, `--exclude FILTER` | Exclude matching URLs |

**Include only specific files**
```bash
# Only images
ruby wayback_machine_downloader https://example.com -o "/\.(jpg|png)/i"

# Only files in a specific folder
ruby wayback_machine_downloader https://example.com --only my_directory
```
You can supply a string or a regex (using the `/regex/` notation).

**Exclude specific files**
```bash
# Everything except images
ruby wayback_machine_downloader https://example.com --exclude "/\.(gif|jpg|jpeg)$/i"
```

---

### Performance
| Option | Description |
|--------|-------------|
| `-c NUM`, `--concurrency NUM` | Concurrent downloads (default: 1) |
| `-p NUM`, `--maximum-snapshot NUM` | Max snapshot pages (150k snapshots/page) |

**Increase concurrency**
```bash
ruby wayback_machine_downloader https://example.com --concurrency 20
```
May significantly speed up the download by fetching multiple files at once.

**Increase snapshot limit**
```bash
ruby wayback_machine_downloader https://example.com --maximum-snapshot 300    
```
100 pages is the default maximum and is sufficient for most websites. Use a bigger number for massive sites.

---

### Diagnostics
| Option | Description |
|--------|-------------|
| `-a`, `--all` | Include error pages (40x/50x) and redirections (30x) |
| `-l`, `--list` | List files without downloading |

**Download all files (including errors)**
```bash
ruby wayback_machine_downloader https://example.com --all
```
By default, the downloader limits itself to 200 OK responses. This flag adds error files (40x, 50x) and redirections (30x), as well as empty files that are usually removed.

**Generate URL list**
```bash
ruby wayback_machine_downloader https://example.com --list
```
Displays a JSON list of files to be downloaded with timestamps and URLs. Useful for debugging or piping to another application.

---

### Job management
The downloader automatically saves its progress (`.cdx.json` for snapshot list, `.downloaded.txt` for completed files) in the output directory. If you run the same command again pointing to the same output directory, it will resume where it left off.

> [!NOTE]
> Automatic resumption can be affected by changing the URL, mode selection (like `--all-timestamps`), or filtering options. If you want to ensure a clean start, use the `--reset` option.

| Option | Description |
|--------|-------------|
| `--reset` | Delete state files (`.cdx.json`, `.downloaded.txt`) and restart the download from scratch. Does not delete already downloaded website files. |
| `--keep` | Keep state files (`.cdx.json`, `.downloaded.txt`) even after a successful download. By default, these are deleted upon completion. |

**Restart a download job**
```bash
ruby wayback_machine_downloader https://example.com --reset
```
Useful if you suspect the state files are corrupted or want a fresh process without deleting your downloaded files.

**Keep state files**
```bash
ruby wayback_machine_downloader https://example.com --keep
```
Useful for debugging or if you plan to extend the download later with different parameters (e.g., adding a `--to` timestamp).

---

## Troubleshooting

### SSL certificate errors
If you encounter an SSL error like:
```text
SSL_connect returned=1 errno=0 state=error: certificate verify failed (unable to get certificate CRL)
```
This is a known issue with **OpenSSL 3.6.0** on certain Ruby installations, not a bug with this WMD fork specifically. (See [ruby/openssl#949](https://github.com/ruby/openssl/issues/949)).

The workaround is to create a file named `fix_ssl_store.rb` with the following content:
```ruby
require "openssl"
store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
OpenSSL::SSL::SSLContext::DEFAULT_PARAMS[:cert_store] = store
```

Then run the downloader using:
```bash
RUBYOPT="-r./fix_ssl_store.rb" wayback_machine_downloader "http://example.com"
```

**Verifying the issue:**
You can test if your Ruby environment has this issue by running this snippet. If it fails with the same SSL error, the workaround above will fix it:
```ruby
require "net/http"
require "uri"

uri = URI("https://web.archive.org/")
Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
  resp = http.get("/")
  puts "GET / => #{resp.code}"
end
```

---

## Contributing
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

**Run tests** (note, these are still broken!):
```bash
bundle exec rake test
```