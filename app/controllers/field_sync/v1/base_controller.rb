# Base das rotas /field/v1/* do app de campo (módulo 24b, ADR 0052; contrato
# §9.2): sem cookie (não inclui Authentication), borda da FieldAuthentication.
# Os comandos recebem `by: @device_user` (e o aparelho, @device); Current.user
# e Current.session ficam nil.
module FieldSync
  module V1
    class BaseController < ApplicationController
      include ::FieldAuthentication

      wrap_parameters false
    end
  end
end
