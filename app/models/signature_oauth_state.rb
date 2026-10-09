# app/models/signature_oauth_state.rb
# State de uso único do OAuth com o PSC (ADR 0032; spec §4, §10): amarrado à
# cidade (pelo token assinado), ao usuário e ao propósito; o code_verifier do
# PKCE cifrado com a chave da cidade.
class SignatureOauthState < ApplicationRecord
  PURPOSES = %w[link session batch].freeze
  TTL = 10.minutes

  encrypts :code_verifier

  belongs_to :user

  def inspect = "#<SignatureOauthState id=#{id} purpose=#{purpose}>"
end
