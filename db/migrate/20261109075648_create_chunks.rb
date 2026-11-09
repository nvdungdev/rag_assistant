class CreateChunks < ActiveRecord::Migration[8.1]
def change
  create_table :chunks do |t|
    t.references :document, null: false, foreign_key: true, index: false
    t.integer :position, null: false
    t.string :heading_path
    t.text :content, null: false
    t.vector :embedding, limit: 1024
    t.timestamps
  end
  add_index :chunks, [ :document_id, :position ], unique: true
end
end
