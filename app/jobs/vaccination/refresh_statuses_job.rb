# Recálculo diário da situação vacinal materializada (ADR 0047, Desvio 11):
# por cidade com `vaccination` utilizável (lido fora de qualquer transação da
# cidade), todos os pacientes com nascimento conhecido, em lotes de 500. O
# nascimento é cifrado: o filtro é em Ruby, e o paciente sem nascimento só tem
# as linhas antigas apagadas (refresh! sem nascimento). Uma falha num paciente
# não para o lote: vai ao log só com o id e a classe do erro, e o job falha no
# fim com a contagem (o EachCityJob junta as cidades).
module Vaccination
  class RefreshStatusesJob < ApplicationJob
    prepend EachCityJob
    queue_as :housekeeping

    BATCH = 500

    def perform
      return unless Gate.usable?(Current.city)

      today = Time.zone.today
      failed = 0
      Patient.in_batches(of: BATCH) do |batch|
        batch.select(:id, :birth_date, :sex).each do |patient|
          Statuses.refresh!(patient, today: today)
        rescue => e
          failed += 1
          Rails.logger.error("[#{self.class.name}] patient=#{patient.id} failed: #{e.class}")
        end
      end
      raise "#{failed} patient(s) failed" if failed.positive?
    end
  end
end
