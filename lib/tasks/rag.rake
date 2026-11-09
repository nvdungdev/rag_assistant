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
end
