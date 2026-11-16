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

  desc "Length stats across guides: rake 'rag:stats[sections]' or 'rag:stats[chunks]'"
  task :stats, [ :mode ] => :environment do |_, args|
    mode = args[:mode] || "sections"
    abort "Usage: rake 'rag:stats[sections|chunks]'" unless %w[sections chunks].include?(mode)

    short_limit = 200
    long_limit  = 1500

    rows = Dir[Rails.root.join("data/guides/*.md")].sort.flat_map do |path|
      file     = File.basename(path)
      sections = Rag::SectionSplitter.call(File.read(path))
      items    = mode == "chunks" ? Rag::Chunker.call(sections) : sections
      items.map do |x|
        { file: file, path: x.heading_path, size: x.text.size, fenced: x.text.match?(/^\s*```/) }
      end
    end

    sizes = rows.map { _1[:size] }.sort
    pct   = ->(p) { sizes[((p / 100.0) * (sizes.size - 1)).round] }
    over  = rows.select { _1[:size] > long_limit }

    puts "mode:        #{mode}"
    puts "files:       #{rows.map { _1[:file] }.uniq.size}"
    puts "items:       #{sizes.size}"
    puts "total chars: #{sizes.sum}"
    puts "min / median / p90 / max: #{sizes.first} / #{pct.(50)} / #{pct.(90)} / #{sizes.last}"
    puts "under #{short_limit}: #{sizes.count { _1 < short_limit }}"
    puts "over #{long_limit}:  #{over.size} (#{over.count { _1[:fenced] }} contain a code fence)"

    show = ->(title, list) do
      puts "\n#{title}"
      list.each { |r| puts format("%6d  %-32s  %s", r[:size], r[:file], r[:path].truncate(90)) }
    end

    sorted = rows.sort_by { _1[:size] }
    show.("5 shortest:", sorted.first(5))
    show.("5 longest:", sorted.last(5).reverse)
  end

  desc "Check that chunking loses no content"
  task chunk_check: :environment do
    bad = 0
    Dir[Rails.root.join("data/guides/*.md")].sort.each do |path|
      sections = Rag::SectionSplitter.call(File.read(path))
      chunks   = Rag::Chunker.call(sections)
      count    = ->(texts) { texts.sum { _1.gsub(/\s+/, "").size } }

      s = count.(sections.map(&:text))
      c = count.(chunks.map(&:text))
      positions_ok = chunks.map(&:position) == (0...chunks.size).to_a

      next if c >= s && positions_ok
      bad += 1
      puts "#{File.basename(path)}: sections=#{s} chunks=#{c} positions_ok=#{positions_ok}"
    end
    puts bad.zero? ? "OK: no content lost in any file" : "#{bad} file(s) with problems"
  end

  desc "Split every document into chunks and store them (idempotent): rake rag:chunk"
  task chunk: :environment do
    total = 0

    Document.order(:id).find_each do |doc|
      chunks = Rag::Chunker.call(Rag::SectionSplitter.call(doc.content))
      rows = chunks.map do |c|
        { document_id: doc.id, position: c.position, heading_path: c.heading_path, content: c.text }
      end

      Document.transaction do
        # Relation-level delete_all really deletes rows.
        # doc.chunks.delete_all would only NULLIFY the FK unless dependent: :delete_all is set.
        Chunk.where(document_id: doc.id).delete_all
        Chunk.insert_all!(rows) if rows.any?
      end

      total += rows.size
      puts format("%-40s %4d chunks", doc.source_path, rows.size)
    end

    puts "--- #{Document.count} documents, #{total} chunks (Chunk.count = #{Chunk.count})"
  end

  desc "Embed chunks that have no embedding yet (resumable). Options: LIMIT=n, BATCH=n"
  task embed: :environment do
    batch_size = Integer(ENV.fetch("BATCH", 16))

    scope = Chunk.where(embedding: nil).order(:id)
    scope = scope.limit(Integer(ENV["LIMIT"])) if ENV["LIMIT"]
    ids = scope.pluck(:id)
    total = ids.size
    puts "chunks to embed: #{total}"

    client = Rag::OllamaClient.new
    clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    started = clock.call
    done = 0

    ids.each_slice(batch_size) do |batch_ids|
      t0 = clock.call

      # Same order as batch_ids (ids are already sorted ascending).
      chunks = Chunk.where(id: batch_ids).order(:id).to_a
      vectors = client.embed(chunks.map(&:embedding_text))

      Chunk.transaction do
        chunks.zip(vectors).each { |chunk, vector| chunk.update_columns(embedding: vector) }
      end

      done += chunks.size
      puts "#{done}/#{total} (batch #{(clock.call - t0).round(1)}s, elapsed #{(clock.call - started).round}s)"
    end

    puts "done in #{(clock.call - started).round}s"
  end
  desc "Ask a question: bin/rails rag:ask Q='your question' [K=5]"
  task ask: :environment do
    question = ENV["Q"].to_s.strip
    abort "Usage: bin/rails rag:ask Q='your question' [K=5]" if question.empty?

    k = Integer(ENV.fetch("K", Rag::Retriever::DEFAULT_K))
    builder = Rag::PromptBuilder.new
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    results = Rag::Retriever.new(k: k).call(question)
    reply = Rag::OllamaClient.new.chat(builder.build(question, results))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    if builder.no_answer?(reply.content)
      puts Rag::PromptBuilder::NO_ANSWER_MESSAGE
    else
      puts reply.content
      puts
      puts "Retrieved from:"
      puts builder.sources(results)
      warn "[warning] answer was cut off (num_predict reached)" if reply.truncated?
    end

    warn format("[debug] top1_distance=%.3f prompt_tokens=%s output_tokens=%s time=%.1fs",
                results.first&.distance.to_f, reply.prompt_tokens, reply.output_tokens, elapsed)
  rescue Rag::OllamaClient::Error, ArgumentError => e
    abort "Error: #{e.message}"
  end
end
