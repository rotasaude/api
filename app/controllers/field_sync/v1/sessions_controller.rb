# GET /field/v1/session (contrato §9.3; Q26): quem é o aparelho, as equipes e
# as microáreas que ele baixa (ACS: responsible; outro CBO da Tabela 7:
# assigned), os interruptores e o primeiro dia aceito. Sem trilha (nenhum dado
# de cidadão). Forma do session-response-v1 do contracts.
module FieldSync
  module V1
    class SessionsController < BaseController
      def show
        render json: FieldSync::Json.session(user: @device_user, member: @device_member, city: Current.city)
      end
    end
  end
end
