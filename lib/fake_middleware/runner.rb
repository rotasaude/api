require_relative "client"
require_relative "messages"

module FakeMiddleware
  # Um ciclo: pendentes → QBP^Q11 → um OUL^R22 por exame conhecido (GLI manda
  # dois: o crítico e a repetição). Log só com contagens, MSH-10 e MSA: nunca
  # etiqueta, valor ou token.
  module Runner
    module_function

    def tick(client:, logger:)
      barcodes = client.pending_barcodes
      if client.last_status == 403
        logger.info("[fake-middleware] fake_middleware (ou lab_hl7_inbound) desligado nesta cidade: nada a fazer")
        return []
      end
      return [].tap { logger.warn("[fake-middleware] pendentes: #{client.last_status}") } unless client.last_status == 200

      logger.info("[fake-middleware] pendentes: #{barcodes.size}")
      barcodes.flat_map do |barcode|
        _status, rsp = client.post(Messages.qbp(barcode))
        spm4 = Messages.spm4(rsp)
        Messages.codes(rsp).flat_map do |code|
          Array(Messages::VALUES[code]).map do |values|
            control = Messages.control_id
            _status, reply = client.post(Messages.oul(barcode, code, values, control: control, spm4: spm4))
            msa = Messages.msa(reply)
            logger.info("[fake-middleware] OUL^R22 MSH-10 #{control} MSA #{msa}")
            [ barcode, code, msa ]
          end
        end
      end
    end
  end
end
