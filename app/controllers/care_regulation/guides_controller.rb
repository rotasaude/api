# A guia de encaminhamento em PDF (contrato §3, §13 G6, G8; plano do api,
# Desvio 13):
#   GET /regulation/requests/:id/guide.pdf
# Lê a autora do pedido, o profissional com vínculo ativo na unidade
# solicitante e o regulador; qualquer outro, o rascunho e o id que não existe
# recebem o mesmo 404 (nada revela a existência). Uma trilha por pessoa
# (`clinical_record.viewed`, access "regulation"). Sem cache; o nome do arquivo
# leva o id inteiro e nenhum dado pessoal. Nenhuma chave na query (nada pessoal
# na URL nem no log).
module CareRegulation
  class GuidesController < BaseController
    def show
      return unless query_only!

      found = uuid?(params[:id]) && RegulationRequest.where.not(status: "draft")
                                                     .preload(:patient, :requester_unit, requester_user: :professional,
                                                              authorizations: { care_offer: :care_provider }).find_by(id: params[:id])
      return not_found unless found && reader?(found)

      bytes = GuidePdf.call(found)
      Trail.person_viewed!(user: Current.user, patient_id: found.patient_id)
      response.headers["Cache-Control"] = "no-store"
      send_data bytes, type: "application/pdf", disposition: "attachment", filename: "guia-regulacao-#{found.id}.pdf"
    end

    private

    def reader?(found)
      return true if regulator? || found.requester_user_id == Current.user.id

      Current.user.has_role?("health_professional") &&
        ProfessionalLink.active.joins(:professional)
                        .exists?(professionals: { user_id: Current.user.id }, health_unit_id: found.requester_unit_id)
    end
  end
end
