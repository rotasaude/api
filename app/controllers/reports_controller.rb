# GET /r/:token — endpoint público do relatório congelado. Ver ADR-0007.
# Verifica HMAC antes de qualquer query indexada — barra varredura.
class ReportsController < ApplicationController
  def show
    snapshot = ReportSnapshot.find_by_signed_token(params[:token])
    return head :not_found unless snapshot

    render json: {
      tier: snapshot.payload["tier"],
      priority: snapshot.payload["priority"],
      summary: snapshot.payload["summary"],
      completed_at: snapshot.payload["completed_at"],
      expires_at: snapshot.expires_at&.iso8601
    }
  end
end
