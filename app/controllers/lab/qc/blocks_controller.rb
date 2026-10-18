# /lab/qc/blocks (contrato §3): lista por laboratório (ativos ou fechados);
# contador sem trilha nos laboratórios da sessão (molde A46/D11; C11); ação
# corretiva de quem opera o aparelho (C14; C-E4: lab_staff ou liberador do laboratório).
module Lab
  module Qc
    class BlocksController < BaseController
      before_action -> { provider! }, only: :index

      def index
        scope = LabQcBlock.joins(:lab_instrument).where(lab_instruments: { exam_provider_id: @provider.id })
        scope = params[:status] == "closed" ? scope.where.not(closed_at: nil) : scope.where(closed_at: nil)
        render json: { blocks: scope.order(opened_at: :desc).limit(200).map { |b| Json.block(b) } }
      end

      # Sem trilha (C-11): a tela consulta em intervalos.
      def count
        ids = Lab::Access.admin?(Current.user) ? Lab::Access.labs.pluck(:id) : Lab::Access.provider_ids(Current.user)
        render json: { count: LabQcBlock.active.joins(:lab_instrument).where(lab_instruments: { exam_provider_id: ids }).count }
      end

      def corrective_action
        block = uuid?(params[:id]) && LabQcBlock.find_by(id: params[:id])
        return not_found unless block
        return forbid unless Lab::Access.member?(Current.user, block.lab_instrument.exam_provider_id)

        result = RecordCorrectiveAction.call(block: block, text: params[:text], by: Current.user)
        return render_failure(result) if result.failure?

        render json: Json.block(result.payload[:block])
      end
    end
  end
end
