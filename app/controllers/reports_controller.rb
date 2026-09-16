# GET /r/:token — endpoint público do relatório congelado. Ver ADR-0010.
# Verifica HMAC antes de qualquer query indexada — barra varredura.
#
# banco da cidade do host (CityResolution), então um token só vale no host da
# própria cidade — o de outra cidade não existe ali. O link enviado ao cidadão
# sai de CityPublicUrl.wpda (host da cidade, Plano 6).
class ReportsController < ApplicationController
  def show
    snapshot = ReportSnapshot.find_by_signed_token(params[:token])
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
