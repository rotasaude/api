# Consumidor de lab_report.released (ADR 0039; contrato §4). Roda na
# transação da cidade (IdempotentConsumer); o portão lê só a plataforma
# (Billing::Gate, sem abrir a cidade), por isso é seguro aqui. Desligado no
# momento da liberação: nada (sem retroativo; runbook).
module Billing
  class LabProductionJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def handle(lab_report_id:, **)
      return unless Gate.enabled?(Current.city)

      report = LabReport.find_by(id: lab_report_id)
      FromLab.call(report) if report
    end
  end
end
