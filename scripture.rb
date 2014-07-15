#coding: utf-8

##########################################################
#モルモン書、教義と聖約、高価な真珠を教会のWebサイトから取り出しCSVに出力するプログラムです。
#
#1Ne4:33ではなぜか文章の途中に不自然な半角スペースが含まれているので手動で削除してください。
#信仰箇条の最後にジョセフ・スミス「が」という変な文字があるので、修正する必要があります。
#アブラハム書の模写の画像はSkipされます。
#教義と聖約の年代順に見た目次は読みこむことができません。
#
##########################################################

require 'nokogiri'
require 'open-uri'
require 'kconv'
require 'csv'

DEBUG = false

#Webサイトアドレスのリストのファイル名
#モルモン書
BOM_WEBPAGE_LIST_FILE = "bom.txt"
#教義と聖約
D_C_WEBPAGE_LIST_FILE = "d_c.txt"
#高価な真珠
POG_WEBPAGE_LIST_FILE = "pog.txt"

#出力先CSVファイルのファイル名
#モルモン書
BOM_OUTPUT_CSV_FILE = "bom.csv"
#教義と聖約
D_C_OUTPUT_CSV_FILE = "d_c.csv"
#高価な真珠
POG_OUTPUT_CSV_FILE = "pog.csv"

#（デバッグ用）聖典のデータを標準出力する
def print_data(data)
	print "[",data[:type],"]"
	print "(",data[:book],")",data[:chapter],":"
	puts data[:verse]
	puts data[:text]
end

#行ごとのデータを切り出す
def get_line_data(line)

	#ルビ、脚注は要らないので中身ごと削除
	(line/"rp").remove
	(line/"rt").remove
	(line/"sup").remove
	
	#文字として取り出す
	text = line.inner_html

	#不要なタグを削除
	text.gsub!(/<\/?ruby>/,"")
	text.gsub!(/<\/?(a|div|span|center|td)[^>]*?>/,"")#bタグを混ぜるとbrタグに引っかかった。b[^r]でもダメ
	text.gsub!(/<\/?b>/,"")
	
	#余分な空白を削除
	text.gsub!(/[\u200b]|[\u00A0]/,"")

	#改行を削除
	text.gsub!(/\n/,"")
	
	#先頭の空白と数値を削除
	text.gsub!(/^(\d*)\s+/,"")
	
	#節番号を保存
	verse_num = $1
	unless verse_num
		#節以外は0とする
		verse_num = 0
	end
	
	#末尾の空白を削除
	text.gsub!(/\s+$/,"")
	
	#デバッグ用：空白をチェック
	#1Ne4:33ではなぜか文章の途中に不自然な半角スペースが含まれているので手動で削除してください。
	#text.gsub!(/\s/,"~")

	#改行タグを改行文字に変換
	#（<br/>表記はなぜかNokogiriが<br>に統一して出力してくれているらしいので/<br\/?>/でなくてもよさそう）
	text.gsub!(/<br>/,"\n")

	#知らないHTMLタグを見つけたらストップ
	if text =~ /<[^>]+?>/
		raise "unknown HTML tag #{$~} found"
	end

	{book: 0,chapter: 0, verse: verse_num, type: '',text: text}

end

#聖典データをWebから取り出し、ハッシュの配列として返す
def get_scripture(webpage_list_file)

	data_arr = []
	book_id = 0
	prev_book = ''
	
	sites = open(webpage_list_file).read.split
	
	#モルモン書の前書きで章数を数えるためにはここで宣言する必要がある
	chapter_num = 0
	
	sites.each do |site|
	
		#book_idの計算
		#WEBのアドレスからhttp://****/@@@@/xxxxのうち
		#@@@@の部分が新しい場合にbook_idを増加させる、
		site =~ /\/([^\/]+)\/([^\/]+)$/
		book_name = $1
		chapter_name = $2
		if prev_book != book_name
			book_id += 1 unless prev_book == ''
			prev_book = book_name
			chapter_num = 0
			#教義と聖約の序文を別に分ける
			prev_book = 'intro' if book_name == 'dc' && chapter_name == 'introduction'
		end
		
		web_data = open(site).read.toutf8
	
		#ドキュメント全体を取得
		html = Nokogiri::HTML(web_data)
		#聖文の部分を取得
		content = html/"table[@class='content']//td"
		
		#class=panelをコンテンツ領域としている場合
		c = content.at("./div[@class!='searchbar' and @class='panel']")
		if c && c['class'] == 'panel'
			content = (content/"./div[@class!='searchbar' and @class='panel']")
		end
		
		#verseは入れ子になっているので排除
		#panelも通常のページでは大枠になっているため、対象から外す
		(content/"./*[((name()='table')or(name()='div'))and(@class!='header' and @class!='footer')]").each do |line|
			
			unless line['class']=="list"
				data = get_line_data line
				data[:book] = book_id
				data[:type] = line['class']
				#章数を章が変わった時にセットする
				if chapter_num == 0 && data[:type] == "subtitle" && data[:text] =~ /第(\d+)章/
					chapter_num = $1
				#モルモン書と教義と聖約、高価な真珠の前書き、公式の宣言も１章から開始する
				elsif chapter_num == 0 && data[:type] == "title" && (book_name == 'bm' || chapter_name == 'introduction' || book_name == 'od' )
					chapter_num = 1
				#章がひとつしかないものも章を１にする（章数が０のまま要約や節に入ったら１にする）
				elsif chapter_num == 0 && (data[:type] == "summary" || data[:type] == "verse")
					chapter_num = 1
				#高価な真珠のアブラハム書の模写は１つずつ章として考える。アブラハム書の最後は５章なので５を加算し、６章からスタート
				elsif  chapter_name =~ /^fac_(\d)$/
					chapter_num = 5 + $1.to_i
				end
				data[:chapter] = chapter_num
				#例外としてなぜか公式の宣言１では<br/>v<br/>というおかしな文字があるので、それを区切りに２つに分ける
				if data[:text] =~ /^v$/
					data_lines = data[:text].split(/\nv\n/)
					data[:text] = data_lines[0]
					data_arr.push data
					print_data data if DEBUG
					data[:text] = data_lines[1]
					data_arr.push data
					print_data data if DEBUG
				else
					data_arr.push data
					print_data data if DEBUG
				end
			#ListはTable要素
			else
				(line/".//tr").each do |tr|
					data = get_line_data tr
					data[:book] = book_id
					data[:type] = 'list'
					data[:chapter] = chapter_num
					data_arr.push data
					print_data data if DEBUG
				end
			end
		end
		
		#モルモン書の前書き、公式の宣言でなければ
		if book_name != 'bm' && book_name != 'od'
			#章数を0に初期化
			chapter_num = 0
		#前書き、公式の宣言、アブラハム書の模写であれば
		else
			#章数をすすめる
			chapter_num += 1
		end

	end
	data_arr
end

def write_scripture_csv(output_csv_file,scripture_data)
	CSV.open(output_csv_file,'w') do |writer|
		scripture_data.each do |data|
			writer << [data[:book],data[:chapter],data[:verse],data[:type],data[:text]]
		end
	end
end

#モルモン書データを取得しCSVに出力
puts "getting 'the Book of Mormon' data from website"
bom = get_scripture(BOM_WEBPAGE_LIST_FILE)
puts "writing 'the Book of Mormon' data to #{BOM_OUTPUT_CSV_FILE}"
write_scripture_csv(BOM_OUTPUT_CSV_FILE,bom) unless DEBUG
puts "Completed!"

#教義と聖約データを取得しCSVに出力
puts "getting 'Dcotorine and Covenants' data from website"
d_c = get_scripture(D_C_WEBPAGE_LIST_FILE)
puts "writing 'Doctorine and Covenants' data to #{D_C_OUTPUT_CSV_FILE}"
write_scripture_csv(D_C_OUTPUT_CSV_FILE,d_c) unless DEBUG
puts "Completed!"

#高価な真珠データを取得しCSVに出力
puts "getting 'Pearl of Great Price' data from website"
pog = get_scripture(POG_WEBPAGE_LIST_FILE)
puts "writing 'Pearl of Great Price' data to #{POG_OUTPUT_CSV_FILE}"
write_scripture_csv(POG_OUTPUT_CSV_FILE,pog) unless DEBUG
puts "Completed!"
