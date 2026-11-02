# lib/fake_rnds/config.ru
# RNDS SIMULADA do compose de dev (ADR 0047, módulo 29). Nunca em produção.
require_relative "app"

abort "fake-rnds nunca sobe em produção" if (ENV["RAILS_ENV"] || ENV["RACK_ENV"]).to_s == "production"

run FakeRnds::App.new
