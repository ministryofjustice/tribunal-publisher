require 'open-uri'
require 'nokogiri'
require 'json'
require 'date'
require 'mechanize'

module Publisher
  extend self

  def session
    @session ||= Capybara::Session.new(:selenium)
  end

  def upload data, decision_type
    return if data.nil?

    form = new_decision_form decision_type

    set_values form, /judges/, data.delete(:judges)
    set_value form, /_category/, data.delete(:category)
    attachments = data.delete(:attachments)

    data.each do |key, value|
      field = "#{decision_type}[#{key}]".to_s
      form[field] = value
    end
    result = form.submit

    title = data[:title]
    result = attach_doc result, attachments[:pdf], 'PDF document', title, decision_type
    result = attach_doc result, attachments[:doc], 'Word document', title, decision_type
    publish result, title
  end

  def new_decision_form decision_type
    agent = Mechanize.new
    agent.agent.http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    if ENV["EDITOR_LOGIN_URL"]
      s = agent.get(ENV["EDITOR_LOGIN_URL"])
      f = s.form
      f['user[email]'] = ENV["EDITOR_USER"]
      f['user[password]'] = ENV["EDITOR_PASSWORD"]
      f.submit
    end
    page = agent.get("#{ENV["EDITOR_HOST"]}/#{decision_type.gsub('_','-')}s")
    page = page.link_with(text: 'New document').click
    page.form
  end

  def set_values form, pattern, selected_values
    if selected_values
      field = form.fields.select{|x| x.name[pattern]}.detect{|x| x.class == Mechanize::Form::MultiSelectList}
      field.value = selected_values
    end
  end

  def set_value form, pattern, selected_value
    if selected_value
      field = form.fields.select{|x| x.name[pattern]}.detect{|x| x.class == Mechanize::Form::SelectList}
      field.value = selected_value.downcase.gsub(' & ',' ').gsub(' ', '-').strip
    end
  end

  def attach_doc result, url, file_type, title, decision_type
    if url
      uri = URI.parse(URI.encode(url))
      if uri.host
        if link = result.link_with(text: 'Edit document')
          page = link.click
          if link = page.link_with(text: 'Add attachment')
            page = link.click
            form = page.form
            upload = form.file_upload
            upload.file_name, upload.file_data = file_data(uri)

            form['attachment[title]'] = title
            edit_page = form.submit
            form = edit_page.form
            form["#{decision_type}[change_note]"] = 'Add attachment.'

            if file_type[/PDF document/]
              text = pdf_text(upload.file_name, upload.file_data)
              form["#{decision_type}[hidden_indexable_content]"] = text
            end
            a = edit_page.search('.attachment').last
            attachment = a.at('.snippet').text
            download = download_markdown(file_type, attachment, title)
            body_field = "#{decision_type}[body]"

            form[body_field] = (form[body_field].sub('N/A', '') + download).strip
            result = form.submit
          end
        end
      end
    end
    result
  end

  def download_markdown file_type, attachment, title
    download = "\n\nDownload decision as a #{file_type}: #{attachment}"
  end

  def file_data uri
    name = uri.path.split('/').last
    file = "./downloads/#{name}"
    File.open(file, "w") {|f| f.write open(uri.to_s).read } unless File.exist?(file)
    file_data = open(file).read
    # return ['./'+name, file_data]
    return [name, file_data]
  end

  def pdf_text file_name, file_data
    file = "./downloads/#{file_name}"
    output = "#{file}.txt"
    File.open(file, "w") {|f| f.write file_data } unless File.exist?(file)
    `pdftotext "#{file}" "#{output}"` unless File.exist?(output)
    text = open(output).read
    text.force_encoding('iso-8859-1').encode('utf-8')
  end

  def publish result, title
    if result.at('h3[text()="Publish document"]') && result.forms.size == 2
      publish_form = result.forms.first
      publish_form.submit
    else
      puts "Can't publish: #{title}"
      puts "Errors were: "
      puts result.at('.alert').text rescue nil
      puts result.at('ul.errors').children.text.split(/\n\s*/).reject{ |s| s == '' } rescue nil
    end
  end

end
