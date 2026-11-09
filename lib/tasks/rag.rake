namespace :rag do
  desc "Load documents from data/manifest.txt (idempotent: safe to re-run)"
  task load_documents: :environment do
    base_url = "https://guides.rubyonrails.org"
    dir      = Rails.root.join("data", "guides")
    names    = File.readlines(Rails.root.join("data", "manifest.txt"), chomp: true)
                   .map(&:strip).reject(&:empty?)
    stats = Hash.new(0)

    # All-or-nothing: if any file fails, nothing is saved.
    Document.transaction do
      names.each do |name|
        # Reject unexpected names (e.g. "../") so we never read outside data/guides.
        raise "Invalid file name in manifest: #{name.inspect}" unless name.match?(/\A[a-z0-9_]+\.md\z/)

        path = dir.join(name)
        raise "Missing file: #{path}" unless path.file?

        content = File.read(path, encoding: "UTF-8")
        title   = Document.extract_title(content) or raise "No Setext title found in #{name}"
        url     = "#{base_url}/#{File.basename(name, '.md')}.html"

        doc = Document.find_or_initialize_by(source_path: name)
        doc.assign_attributes(title: title, url: url, content: content)
        status = doc.new_record? ? :created : (doc.changed? ? :updated : :unchanged)
        doc.save!
        stats[status] += 1
        puts "#{status.to_s.ljust(9)} #{name} -> #{title}"
      end
    end

    puts "Done: #{stats.inspect}. Total documents: #{Document.count}"
  end

  desc "Preview sections of a guide: rake 'rag:preview[active_record_basics.md]'"
  task :preview, [ :file ] => :environment do |_, args|
    path = Rails.root.join("data/guides", args[:file])
    md = File.read(path)
    sections = Rag::SectionSplitter.call(md)

    sections.each do |s|
      puts format("%5d  %-60s  %s", s.text.size, s.heading_path.truncate(60), s.text[0, 70].tr("\n", " "))
    end
    puts "--- #{sections.size} sections, #{sections.sum { _1.text.size }} / #{md.size} chars in file"
  end
end
