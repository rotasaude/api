# GET /r/:token — endpoint público do relatório congelado. Ver ADR-0010.
# Verifica HMAC antes de qualquer query indexada — barra varredura.
#
# Sem usuário autenticado: o token assinado é a credencial. O snapshot mora no
# banco da cidade do host (CityResolution), então um token só vale no host da
# própria cidade — o de outra cidade não existe ali. O link enviado ao cidadão
# ainda sai de WPDA_PUBLIC_BASE (ReportSnapshot#url); derivá-lo do slug é da
# spec §5 (frontends), fora deste lote.
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
