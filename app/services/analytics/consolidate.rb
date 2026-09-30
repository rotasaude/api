# app/services/analytics/consolidate.rb
module Analytics
  # Refaz os fatos da janela [from, to] a partir do cru (spec §4.1): apaga os
  # dias da janela e regrava, um consolidador por frente. Roda na transação de
  # quem chama (Analytics::Run) — sozinho, uma falha no meio deixaria a janela
  # pela metade.
  module Consolidate
    def self.fronts = [ Demand, Quality, Calibration, Epidemiology ]

    def self.call(from:, to:, at: Time.current)
      AnalyticsDailyFact.where(day: from..to).delete_all
      fronts.each { |front| front.call(from: from, to: to, at: at) }
    end
  end
end
