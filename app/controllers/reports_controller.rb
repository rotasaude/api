# GET /r/:token — endpoint público do relatório congelado. Ver ADR-0010.
# Quem barra varredura é o token: 256 bits aleatórios (ReportSnapshot.mint_token),
# imprevisíveis. A ordem real é: lookup pelo índice único de `token`, DEPOIS a
# comparação em tempo constante do HMAC guardado na linha com o HMAC do token
# sob a chave da cidade (e a legada, na transição), e a checagem de
# expires_at — ver ReportSnapshot.find_by_signed_token. Não há HMAC antes da
# query: a URL leva só o token, a assinatura mora no banco.
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
