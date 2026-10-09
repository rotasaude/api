# app/commands/signatures/run_batch.rb
# Assina o lote aprovado (ADR 0032; spec §5; contrato §5, §13). Abre a própria
# transação; SKIP LOCKED — o pedido que o job já está assinando fica de fora do
# resultado, sem espera (Review Focus 1). Uma chamada ao PSC com todos os
# hashes (Signing, em ordem cronológica, com a cadeia dos adendos). Falha do
# PSC/signer vira item de `failed` (200) e o pedido continua pending com o
# motivo, somando tentativa só como o SignPending#settle (passageira e não
# definitiva). Interruptor inutilizável: os pedidos tocados voltam ao papel.
module Signatures
  module RunBatch
    module_function

    def call(user:, request_ids:, token:, now: Time.current, signer: Signer.client)
      ApplicationRecord.transaction do
        requests = SignatureRequest.where(id: Array(request_ids), author_user_id: user.id, status: "pending")
                                   .order(:created_at, :id).lock("FOR UPDATE SKIP LOCKED").to_a
        next Result.ok(record: { signed: 0, failed: [] }) if requests.empty?

        unless Gate.usable?(Current.city)
          requests.each { |request| ToPaper.call(request, reason_code: "feature_disabled", now: now) }
          next Result.fail(:feature_disabled)
        end

        certificate = SignerCertificate.active.find_by(user_id: user.id)
        next Result.fail(:certificate_not_linked) unless certificate

        reason = CertificateRules.reason(certificate, now: now)
        next Result.ok(record: report(Signing::Outcome.new(signed: [], failed: requests.map { |request| [ request, reason ] }), now)) if reason

        outcome = begin
          Signing.call(requests: requests, access_token: token.access_token, certificate: certificate, now: now, signer: signer)
        rescue Psc::Unavailable, Psc::Rejected, Signer::Unavailable => e
          Signing::Outcome.new(signed: [], failed: requests.map { |request| [ request, reason_for(e) ] })
        end
        Result.ok(record: report(outcome, now))
      end
    end

    # Psc::Unauthorized é um Rejected: token recém-emitido recusado não é sessão vencida.
    def reason_for(error)
      case error
      when Psc::Unavailable then "provider_unavailable"
      when Psc::Rejected then "provider_rejected"
      else "signer_unavailable"
      end
    end

    # Como o SignPending#settle: passageira e não definitiva soma tentativa.
    def report(outcome, now)
      outcome.failed.each do |request, reason|
        transient = SignatureRequest::TRANSIENT_REASONS.include?(reason) && !outcome.final.include?(request.id)
        Park.call(request, reason, transient: transient, now: now)
      end
      { signed: outcome.signed.size,
        failed: outcome.failed.map { |request, reason| { request_id: request.id, reason_code: reason } } }
    end
    private_class_method :reason_for, :report
  end
end
