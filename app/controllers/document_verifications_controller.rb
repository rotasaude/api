# app/controllers/document_verifications_controller.rb
# Página pública de conferência (ADR 0033; contrato §7): sem login, no host
# da cidade (CityResolution), como /r/:token. Limites por IP (Valores fixados
# 3). JSON com Accept: application/json; HTML no navegador (o QR code).
class DocumentVerificationsController < ApplicationController
  module RateLimitStore
    def self.increment(...) = Rails.cache.increment(...)
  end

  LIMITED = -> { render json: { error: "rate_limited" }, status: :too_many_requests }
  rate_limit to: 10, within: 10.minutes, only: :lookup, name: "document_lookup", by: -> { request.remote_ip },
             store: RateLimitStore, with: LIMITED
  rate_limit to: 60, within: 10.minutes, only: :show, name: "document_show", by: -> { request.remote_ip },
             store: RateLimitStore, with: LIMITED
  rate_limit to: 30, within: 10.minutes, only: :signed_pdf, name: "document_signed_pdf", by: -> { request.remote_ip },
             store: RateLimitStore, with: LIMITED

  def form = html(ClinicalDocuments::Page.form)

  def show
    document = ClinicalDocuments::Verification.by_token(params[:token])
    return not_found unless document

    data = ClinicalDocuments::Verification.public_json(document)
    response.headers["Cache-Control"] = "no-store"
    json? ? render(json: data) : html(ClinicalDocuments::Page.result(data))
  end

  def lookup
    input = request.request_parameters
    document = ClinicalDocuments::Verification.lookup(short_code: input["short_code"], birth_year: input["birth_year"])
    return render(json: { error: "not_found" }, status: :not_found) unless document

    render json: ClinicalDocuments::Verification.public_json(document)
  end

  def signed_pdf
    document = ClinicalDocuments::Verification.by_token(params[:token])
    signature = document && !document.cancelled? && ClinicalDocuments::Verification.signature(document)
    return render(json: { error: "not_found" }, status: :not_found) unless signature

    response.headers["Cache-Control"] = "no-store"
    send_data signature.signed_pdf_bytes, type: "application/pdf", disposition: "inline", filename: "documento-assinado.pdf"
  end

  private

  def json? = request.headers["Accept"].to_s.include?("application/json")
  def html(body, status: :ok) = render(body: body, content_type: "text/html; charset=utf-8", status: status)

  def not_found
    json? ? render(json: { error: "not_found" }, status: :not_found) : html(ClinicalDocuments::Page.layout("<p>Documento não encontrado.</p>"), status: :not_found)
  end
end
