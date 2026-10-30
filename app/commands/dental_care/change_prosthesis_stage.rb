# Etapa do pedido de prótese (ADR 0046; Desvio 12; contrato §16 O10, O27):
# impression → sent → received, ou cancelled antes de instalado (motivo de
# 10..500, cifrado). Quem muda: vínculo ativo de papel odontológico na unidade
# do pedido, ou municipal_admin. `installed` só pela finalização da consulta
# (DentalCare::Materialize). Trava o pedido; fora de ordem → invalid_transition.
module DentalCare
  module ChangeProsthesisStage
    NEXT = { "impression" => %w[sent cancelled], "sent" => %w[received cancelled], "received" => %w[cancelled] }.freeze
    SETTABLE = %w[sent received cancelled].freeze

    module_function

    # -> Result.ok(order:) | fail(:missing_role | :installation_through_consultation | :invalid_request | :invalid_transition | :reason_required)
    def call(order:, stage:, reason:, by:)
      ApplicationRecord.transaction(requires_new: true) do
        order.lock!
        next Result.fail(:missing_role) unless allowed?(order, by)
        next Result.fail(:installation_through_consultation) if stage == "installed"
        next Result.fail(:invalid_request, details: { path: "stage", problems: [ { path: "stage", error: "invalid_request" } ] }) unless SETTABLE.include?(stage)
        next Result.fail(:invalid_transition) unless NEXT.fetch(order.stage, []).include?(stage)

        if stage == "cancelled"
          text = reason.is_a?(String) ? reason.strip : nil
          next Result.fail(:reason_required, details: { path: "reason", problems: [ { path: "reason", error: "reason_required" } ] }) unless text && Catalog::REASON.cover?(text.length)
        end
        order.update!(stage: stage)
        order.stages.create!(stage: stage, by_user: by, reason: stage == "cancelled" ? text : nil)
        DomainEvents.publish("prosthesis_order.stage_changed", order_id: order.id, stage: stage, user_id: by.id)
        Result.ok(order: order)
      end
    end

    def allowed?(order, by)
      return true if by.has_role?("municipal_admin")

      Consultations::Authorization.link_for(user: by, health_unit_id: order.health_unit_id, kind: "dental").first == :ok
    end
    private_class_method :allowed?
  end
end
