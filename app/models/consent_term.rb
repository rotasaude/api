# Termo de consentimento da cidade, append-only (ADR-0013).
class ConsentTerm < ApplicationRecord
  validates :version, :body, :published_at, presence: true
end
