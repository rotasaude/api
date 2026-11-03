# Ajuda de custo do TFD (ADR 0048, Desvio 14): uma linha por (trecho, pessoa,
# código), com o valor da tabela SIGTAP, o complemento municipal e o total.
# Imutável (trigger); vira uma linha do BPA (performed_procedures, source tfd).
class TfdAllowance < ApplicationRecord
  belongs_to :tfd_case, inverse_of: :tfd_allowances
  belongs_to :tfd_leg, inverse_of: :tfd_allowances
  has_one :performed_procedure, inverse_of: :tfd_allowance, dependent: :restrict_with_error

  def inspect = "#<TfdAllowance id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
