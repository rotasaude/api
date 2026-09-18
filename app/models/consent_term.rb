# Termo de consentimento da cidade, append-only (ADR-0013).
#
# `version` é STRING no banco, mas o consentimento a grava em
# `consents.version` (INTEGER): só versões inteiras fazem sentido, e é isso que
# permite ordenar numericamente (o MAX de string diria que "9" > "10").
class ConsentTerm < ApplicationRecord
  validates :version, :body, :published_at, presence: true
  validates :version, format: { with: /\A\d+\z/ }, allow_blank: true

  # Versão vigente do termo (String), ou nil se a cidade não tem termo.
  def self.current_version
    order(Arel.sql("version::bigint DESC")).pick(:version)
  end
end
