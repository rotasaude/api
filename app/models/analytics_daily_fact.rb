# Contagem de um dia num recorte (ADR 0025; spec 2026-09-30 §3.1). Nenhuma
# coluna de pessoa. Escrita só por Analytics::Consolidate (INSERT ... SELECT);
# a contagem é gravada crua e a supressão de 1 a 4 é da leitura, depois de
# somar período e recorte.
class AnalyticsDailyFact < ApplicationRecord
  METRICS = %w[triage.started triage.completed triage.aborted attendance.checked_in attendance.closed
               attendance.wait appointment.ended request.opened request.closed calibration.outcome
               epi.answer].freeze
  # Espera entre check-in e chamada, em minutos (desvio 12 do plano).
  WAIT_BUCKETS = %w[0-15 15-30 30-60 60-120 120+].freeze
end
