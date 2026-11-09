class Chunk < ApplicationRecord
  belongs_to :document
  has_neighbors :embedding
end
