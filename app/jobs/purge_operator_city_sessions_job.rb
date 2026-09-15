# Purga, em cada cidade ativa, as sessões de operador abertas por grant que já
# passaram de Session::OPERATOR_GRANT_TTL (Plano 4) — não autenticam mais
# (Session#usable?). Sessão de usuário não é tocada.
class PurgeOperatorCitySessionsJob < ApplicationJob
  prepend EachCityJob
  queue_as :housekeeping

  def perform
    Session.where.not(operator_id: nil).where("created_at < ?", Session::OPERATOR_GRANT_TTL.ago).delete_all
  end
end
