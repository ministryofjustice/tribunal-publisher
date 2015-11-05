env = ENV["ENV"] || "development"
puts "ENV: #{env}"
require "dotenv"
Dotenv.load(File.expand_path("../.env.#{env}", __FILE__))
require_relative 'publisher'
require 'pry'
require 'openssl'
I_KNOW_THAT_OPENSSL_VERIFY_PEER_EQUALS_VERIFY_NONE_IS_WRONG = nil
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

module TaxDecisionScraper
  extend self
  def scrape_and_publish
    scrape_page "http://www.tribunals.gov.uk/financeandtax/Decisions.htm"
    scrape_page "http://www.tribunals.gov.uk/financeandtax/Decisions/Financial.htm", "Financial Services"
    scrape_page "http://www.tribunals.gov.uk/financeandtax/Decisions/Pensions.htm", "Pensions"
  end

  def scrape_page uri, category=nil
    begin
      html = open(uri).read
      doc = Nokogiri::HTML html
    rescue OpenURI::HTTPError => e
      puts "===="
      puts "Error fetching from #{uri} : #{e.to_s}.  Trying the next record."
      increment_error_count!
      if error_count > 10
        puts "More than 10 errors were encountered when scraping. Exiting."
        exit
      end
    end
    items = doc.search('a').select{|x| x['href']}.select{|x| x['href'][/Documents\//]}
    download [items.first], category
  end

  def download items, category
    items.select! do |item|
      title = item.text.strip
      case title
      when "Annex to judgement"
        false
      else
        true
      end
    end

    items.each do |item|
      download_item item, category
    end
  end

  def download_item item, category
    metadata = metadata(item, category)
    log metadata
    published_url = published_url metadata
    publish_item published_url, metadata
  end

  def publish_item published_url, metadata
    begin
      @publish = false
      puts published_url
      if ENV["FRONTEND_USER"] && ENV["FRONTEND_PASSWORD"]
        open(published_url, http_basic_authentication: [ENV["FRONTEND_USER"], ENV["FRONTEND_PASSWORD"]])
      else
        open(published_url)
      end
    rescue Exception => e
      puts e.to_s + " - so will try to upload it."
      @publish = true
    end

    if @publish
      Publisher.upload(metadata, "tax_tribunal_decision")
    else
      puts "Did not publish #{metadata[:title]}."
    end
  end

  def published_url metadata
    slug = metadata[:title].downcase.gsub(/[^a-z0-9\-_]+/, '-')
    "#{ENV["FRONTEND_HOST"]}/tax-and-chancery-tribunal-decisions/#{slug}"
  end

  def log metadata
    puts "Release date: " + metadata[:tribunal_decision_decision_date].to_s
    puts "\n==="
  end

  def category item
    h2 = item.parent.parent.previous_element
    while h2.name != "h2"
      begin
        h2 = h2.previous_element
      rescue
        raise "No category found: #{title}"
      end
    end

    category = h2.text.strip
    category = 'Banking' if category[/Bradford|Northern/]
    category
  end

  def summary item, title, category
    summary = if category.nil?
      item.parent.text.sub("Name: ","").sub(title,"").strip.sub(/\([^\)]+\)/,"").strip.sub(/^"/,"").chomp('"').strip
    else
      p = item.parent.next_element
      if p.name == "p"
        p.text
      else
        puts "Not para: " + p.inspect
        summary = "-"
      end
    end
    if summary && summary.size == 0
      summary = "-"
    end
    summary.gsub("\r\n", "\n")
  end

  def metadata item, category
    title = item.text.strip
    link = item['href']
    url = 'http://www.tribunals.gov.uk/financeandtax/'+link.sub('../','')
    puts title
    puts url
    summary = summary(item, title, category)
    category = category(item) unless category

    release_date = release_date(url)
    if release_date
      release_date = Date.parse(release_date).to_s
    else
      puts [title, url, 'no release date'].join("\t")
    end

    {
      title: fix_encoding(title),
      summary: fix_encoding(summary).strip,
      body: 'N/A',
      category: category,
      tribunal_decision_decision_date: release_date,
      attachments: {
        pdf: url
      }
    }
  end

  def release_date url
    uri = URI.parse(URI.encode(url))
    file_name, file_data = Publisher.file_data(uri)
    text = Publisher.pdf_text(file_name, file_data)

    regexp = /(release date|decision released|released on|released|release|issued to the parties on):(.*\d\d\d\d)/i
    date = text[regexp, 2]

    if !date
      regexp = /(release date)\s+(\d.*\d\d\d\d)/i
      date = text[regexp, 2]
      if !date
        regexp = /(released on)\s+(\d.*\d\d\d\d)/i
        date = text[regexp, 2]
        if !date
          regexp = /(released)\s+(\d.*\d\d\d\d)/i
          date = text[regexp, 2]
          if !date
            date = case url
            when /Summary1_ ISC_v_Charity_2_HM_AGref_v_TheCharityComm|CompoundInterestProject_v_HMRevenueCustoms|MrMrsColl1|BaljinderSingh|R-ELS-Group-Ltd-v-HMRC|McKeown-v-Border-Revenue|HMRC-v-IA-Associates-ltd|pete_matthews_Keith_Sidwick|Weightwatchers_and_ORS_v_HMRC_rvsd/
              nil
              # let nil date pass
            when /hmrc-v-cooneen-watts-stone/
              "24 January 2014"
            when /hmrc-v-Able-UK-ltd/
              "27 June 2013"
            when /hmrc_v_photron_europe_ltd/
              "30 July 2012"
            when /Queen-Application-De-Silva-Dokelman-v-Commissioners-HMRC/
              "15 April 2014"
            when /HMRC_v_Total_People_Limited/
              "25 November 2011"
            when /HMRC_v_LegalGeneral/
              "12 October 2010"
            when /HMRC_v_LondonClubsMgt/
              "5 October 2010"
            else
              puts "No date: " +  url + "   " + text[regexp].to_s
            end
          end
        end
      end
    end

    date = date.to_s.strip.sub(/(\d\d\d\d).*/,'\1').split('Amended').first.sub('th','') if date
    if date == "© CROWN COPYRIGHT 2015"
      nil
    else
      date
    end
  end

  def increment_error_count!
    @error_count = 0 unless @error_count
    @error_count = @error_count + 1
  end

  def error_count
    @error_count
  end

  def fix_encoding text
    if text
      text.gsub!("\u0096",'-')
      text.gsub!("\u0097",'-')
      text.gsub!("\u0093",'"')
      text.gsub!("\u0094",'"')
      text
    else
      text
    end
  end

end

TaxDecisionScraper.scrape_and_publish
