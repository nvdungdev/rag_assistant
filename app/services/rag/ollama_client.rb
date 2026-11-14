require "net/http"
require "json"

module Rag
  class OllamaClient
    class Error < StandardError; end

    ChatResult = Struct.new(:content, :done_reason, :prompt_tokens, :output_tokens, keyword_init: true) do
      def truncated?
        done_reason == "length"
      end
    end

    DEFAULT_URL = "http://localhost:11434"
    DEFAULT_MODEL = "bge-m3"
    DEFAULT_CHAT_MODEL = "qwen3:1.7b"
    EXPECTED_DIMENSION = 1024

    def initialize(url: ENV.fetch("OLLAMA_URL", DEFAULT_URL),
                   model: ENV.fetch("OLLAMA_EMBED_MODEL", DEFAULT_MODEL),
                   chat_model: ENV.fetch("OLLAMA_CHAT_MODEL", DEFAULT_CHAT_MODEL),
                   open_timeout: 5,
                   read_timeout: 300,
                   chat_read_timeout: 180)
      @base_uri = URI(url)
      @model = model
      @chat_model = chat_model
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @chat_read_timeout = chat_read_timeout
    end

    # Accepts a String or an Array of Strings.
    # Returns an Array of vectors (Array<Array<Float>>), same order as input.
    def embed(texts)
      texts = Array(texts)
      return [] if texts.empty?

      body = post("/api/embed", { model: @model, input: texts }, read_timeout: @read_timeout)
      embeddings = body["embeddings"]
      validate!(embeddings, texts.size)
      embeddings
    end

    # messages: [{ role: "system" | "user" | "assistant", content: "..." }]
    def chat(messages, temperature: 0.2, num_ctx: 4096, num_predict: 512, keep_alive: "10m")
      payload = {
        model: @chat_model,
        messages: messages,
        stream: false,
        think: false,           # top-level, not inside options
        keep_alive: keep_alive, # top-level, not inside options
        options: { num_ctx: num_ctx, num_predict: num_predict, temperature: temperature }
      }

      body = post("/api/chat", payload, read_timeout: @chat_read_timeout)

      ChatResult.new(
        content: body.dig("message", "content").to_s.strip,
        done_reason: body["done_reason"],
        prompt_tokens: body["prompt_eval_count"],
        output_tokens: body["eval_count"]
      )
    end

    private

    def post(path, payload, read_timeout:)
      uri = @base_uri.merge(path)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: read_timeout
      ) { |http| http.request(request) }

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Ollama #{path} returned #{response.code}: #{response.body.to_s[0, 300]}"
      end

      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Ollama timeout (#{e.class}) at #{@base_uri}#{path}"
    rescue SocketError, SystemCallError => e
      raise Error, "Cannot reach Ollama at #{@base_uri}: #{e.message}"
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON from Ollama: #{e.message}"
    end

    def validate!(embeddings, expected_count)
      unless embeddings.is_a?(Array) && embeddings.size == expected_count
        raise Error, "Expected #{expected_count} embeddings, got #{embeddings.is_a?(Array) ? embeddings.size : embeddings.class}"
      end

      bad = embeddings.find { |v| !v.is_a?(Array) || v.size != EXPECTED_DIMENSION }
      raise Error, "Unexpected embedding dimension: #{bad.is_a?(Array) ? bad.size : bad.class}" if bad
    end
  end
end
