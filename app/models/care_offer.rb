# Oferta mensal de um prestador para um alvo (especialidade CBO ou procedimento
# SIGTAP), com a cota (quantity). O usado não mora aqui: é a contagem das
# autorizações não liberadas (Desvio 3). Nunca é apagada (trigger).
class CareOffer < ApplicationRecord
  belongs_to :care_provider, inverse_of: :offers
  belongs_to :updated_by_user, class_name: "User"
  has_many :authorizations, class_name: "RegulationAuthorization", inverse_of: :care_offer, dependent: :restrict_with_error

  def month_label = month.strftime("%Y-%m")
end
