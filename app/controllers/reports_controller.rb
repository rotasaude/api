# GET /r/:token — endpoint público do relatório congelado. Ver ADR-0007.
# Verifica HMAC antes de qualquer query indexada — barra varredura.
#
# Endpoint INHERENTEMENTE cross-tenant: o token assinado é a credencial e
# vale para qualquer município. Sem usuário autenticado, não há
# membership/tenant a resolver. Lookup via BYPASSRLS (rota_admin).
class ReportsController < ApplicationController
  skip_tenant_scope

  def show
    snapshot = ApplicationRecord.connected_to(role: :admin) do
      ReportSnapshot.find_by_signed_token(params[:token])
    end
    return head :not_found unless snapshot

    render json: {
      tier: snapshot.payload["tier"],
      priority: snapshot.payload["priority"],
      recommendation: snapshot.payload["recommendation"],
      summary: snapshot.payload["summary"],
      completed_at: snapshot.payload["completed_at"],
      expires_at: snapshot.expires_at&.iso8601
    }
  end
end
