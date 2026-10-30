# GET/PUT /dental/admin/auxiliary_procedures (contrato §16): a lista do TSB/ASB
# da cidade. Só o municipal_admin; escrita com step-up.
module DentalCare
  module Admin
    class AuxiliaryProceduresController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: :update

      def show = render(json: list_json)

      def update
        result = SaveAuxiliaryProcedures.call(codes: codes_from(body["procedures"]), by: Current.user)
        return render_failure(result) if result.failure?

        render json: list_json
      end

      private

      # `[ { sigtap } ]` → códigos; item que não é objeto vira nil (recusado com o path dele).
      def codes_from(list) = list.is_a?(Array) ? list.map { |item| item.is_a?(Hash) ? item["sigtap"] : nil } : list

      # Nome da release SIGTAP ativa; código fora dela → name: null.
      def list_json
        codes = DentalAuxiliaryProcedure.order(:procedure_code).pluck(:procedure_code)
        release = Terminology::Sigtap.release_for(nil)
        names = release ? SigtapProcedure.where(release_id: release.id, code: codes).pluck(:code, :name).to_h : {}
        { procedures: codes.map { |code| { sigtap: code, name: names[code] } } }
      end
    end
  end
end
