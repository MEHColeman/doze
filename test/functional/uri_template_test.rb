require 'functional/base'

class URITemplateTest < Test::Unit::TestCase
  include Doze::Utils
  include Doze::TestCase

  def test_match
    a = Doze::URITemplate.compile("/abc/{x}/def")
    assert_equal({:x => '123'}, a.match("/abc/123/def"))
    assert_equal({:x => ' /'}, a.match("/abc/%20%2F/def"))
    assert_equal([{:x => '123'}, '/abc/123/def', '/ghi'], a.match_with_trailing("/abc/123/def/ghi"))
  end

  def test_match_with_trailing_with_path_separator
    a = Doze::URITemplate.compile("/abc/{x}")
    assert_equal([{:x => '123'}, '/abc/123', '/def'], a.match_with_trailing("/abc/123/def"))
  end

  def test_addition
    a = Doze::URITemplate.compile("/abc/{x}") + Doze::URITemplate.compile("/def/{y}")
    assert_equal({:x => '1', :y => '2'}, a.match("/abc/1/def/2"))
    assert_equal([:x, :y], a.variables)
  end

  def test_expand
    a = Doze::URITemplate.compile("/abc/{x}/def/{y}")
    assert_equal("/abc/123/def/", a.expand(:x => 123))
    assert_equal("/abc/123/def/456", a.expand(:x => 123, :y => 456))
    assert_equal("/abc/123/def/%20%2F", a.expand(:x => 123, :y => ' /'))
  end

  def test_partial_expand
    a = Doze::URITemplate.compile("/abc/{x}") + Doze::URITemplate.compile("/def/{y}")
    assert_equal("/abc/123/def/{y}", a.partially_expand(:x => 123).to_s)
    assert_equal([:y], a.partially_expand(:x => 123).variables)
    assert_equal({:y => '456'}, a.partially_expand(:x => 123).match('/abc/123/def/456'))
    assert_equal("/abc/{x}/def/456", a.partially_expand(:y => 456).to_s)
    assert_equal("/abc/123/def/456", a.partially_expand(:x => 123).expand(:y => 456))
  end
end
