# GET /field/v1/reference (módulo 24c, ADR 0053; contrato §3.5): dicionários,
# bairros, unidades, profissionais das equipes do aparelho e domínios da visita
# e da atividade, para o app montar os formulários offline. Sem query e sem
# trilha (nenhum dado de cidadão). Forma do reference-response-v1 do contracts.
module FieldSync
  module V1
    class ReferencesController < BaseController
      def show
        render json: FieldSync::Reference.build(user: @device_user, city: Current.city)
      end
    end
  end
end
