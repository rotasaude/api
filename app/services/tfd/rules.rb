# Recusas do laudo de TFD no envio e de novo na autorização (plano, Desvio
# 11), todas de uma vez em `problems[]`:
#   distance_below_minimum  destino a menos de `tfd_min_distance_km`;
#   metropolitan_destination;
#   invalid_sigtap_code     fora da SIGTAP ativa da competência de hoje (ou ausente);
#   primary_care_procedure  Tfd::PrimaryCare;
#   cid_required;
#   justification_required  fora de 20..2000 caracteres.
# Só na autorização: appointment_required e billing_unit_missing (com
# procedure_billing ligado e sem `tfd_billing_health_unit_id`). O interruptor
# do faturamento é lido FORA da transação da cidade: quem chama dentro dela
# passa `billing_enabled:`. Só lê; nunca loga o laudo.
module Tfd
  module Rules
    SIGTAP = Billing::Record::CODE

    module_function

    # O CID-10 digitado: nil, o código normalizado ou :invalid (o normalizador
    # do faturamento, ClinicalTerms.cid10_code; sem cópia).
    def cid10(value) = ClinicalTerms.cid10_code(value)

    # -> [ { path:, error: } ]
    def problems(tfd_case, settings:, stage: :submit, billing_enabled: nil)
      report = tfd_case.report || {}
      destination = tfd_case.transport_destination
      list = []
      list << problem("destination_id", "distance_below_minimum") if destination.distance_km < settings.tfd_min_distance_km
      list << problem("destination_id", "metropolitan_destination") if destination.metropolitan
      code = report["sigtap_code"]
      list << problem("report.sigtap_code", "invalid_sigtap_code") unless sigtap_procedure(code)
      list << problem("report.sigtap_code", "primary_care_procedure") if PrimaryCare.covers?(code)
      list << problem("report.cid10", "cid_required") if report["cid10"].blank?
      list << problem("report.justification", "justification_required") unless justification?(report["justification"])
      list.concat(authorize_problems(tfd_case, settings, billing_enabled)) if stage == :authorize
      list
    end

    def authorize_problems(tfd_case, settings, billing_enabled)
      list = []
      list << problem("appointment_at", "appointment_required") if tfd_case.appointment_at.nil?
      billing = billing_enabled.nil? ? Billing::Gate.enabled?(Current.city) : billing_enabled
      list << problem("tfd_billing_health_unit_id", "billing_unit_missing") if billing && settings.tfd_billing_health_unit_id.nil?
      list
    end

    # O procedimento na SIGTAP ativa da competência de hoje | nil (fora dela,
    # ou código fora do formato). Também dá o `sigtap_name` do <tfd-case>.
    def sigtap_procedure(code)
      return nil unless code.is_a?(String) && code.match?(SIGTAP)

      release = Terminology::Sigtap.release_for(Time.zone.today.strftime("%Y%m"))
      release && SigtapProcedure.find_by(release_id: release.id, code: code)
    end

    def justification?(text) = text.is_a?(String) && Catalog::JUSTIFICATION.cover?(text.strip.length)
    def problem(path, error) = { path: path, error: error }
    private_class_method :authorize_problems, :justification?, :problem
  end
end
