class Chunk < ApplicationRecord
  belongs_to :document
  has_neighbors :embedding

  # Text sent to the embedding model (variant B from the pilot):
  # heading path, blank line, then content. Blank parts are skipped.
  def embedding_text
    [ heading_path, content ].map(&:to_s).reject(&:blank?).join("\n\n")
  end
end
