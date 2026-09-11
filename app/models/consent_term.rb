# Termo de consentimento por município, append-only (ADR-0013).
class ConsentTerm < ApplicationRecord
  belongs_to :municipality
  validates :version, :body, :published_at, presence: true
end
