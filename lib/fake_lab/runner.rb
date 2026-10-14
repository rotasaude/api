require_relative "client"
require_relative "report"

module FakeLab
  # Um ciclo: pede as guias e envia um laudo para cada uma ainda sem laudo.
  # Nunca loga corpo, CPF nem token — só o código curto e o status.
  module Runner
    module_function

    def tick(client:, logger:)
      requests = client.service_requests
      if client.last_status == 403
        logger.info("[fake-lab] fake_lab desligado (ou exam_fhir_inbound) nesta cidade: nada a fazer")
        return []
      end
      if client.last_status != 200
        logger.warn("[fake-lab] ServiceRequest: #{client.last_status}")
        return []
      end
      requests.map do |sr|
        code = sr.dig("identifier", 0, "value")
        status = client.send_report(Report.build(sr))
        (200..299).cover?(status) ? logger.info("[fake-lab] guia #{code}: #{status}") : logger.warn("[fake-lab] guia #{code}: #{status}")
        [ code, status ]
      end
    end
  end
end
