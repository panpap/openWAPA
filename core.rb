load 'convert.rb'
load 'trace.rb'
load 'filters.rb'
require 'digest/sha1'

class Core
	attr_writer :window, :cwd
	attr_accessor :database
   	@isBeacon=false

	def initialize(defs,filters)
		@defines=defs
		@convert=Convert.new(@defines)
		@filters=filters	
		@trace=Trace.new(@defines)
		@options=@defines.options
		@window=-1
		@cwd=nil
		@params_cs=Hash.new(nil)
		@database=nil
	end
	
	def makeDirsFiles()
		@defines.puts "> Creating Directories..., "
		Dir.mkdir @defines.dirs['rootDir'] unless File.exists?(@defines.dirs['rootDir'])
		Dir.mkdir @defines.dirs['dataDir'] unless File.exists?(@defines.dirs['dataDir'])
		Dir.mkdir @defines.dirs['adsDir'] unless File.exists?(@defines.dirs['adsDir'])
		Dir.mkdir @defines.dirs['userDir'] unless File.exists?(@defines.dirs['userDir'])
		Dir.mkdir @defines.dirs['timelines'] unless File.exists?(@defines.dirs['timelines'])	
		if @options["database?"]
			@defines.puts "and database tables..."
			@database=Database.new(@defines,nil)
			@defines.tables.values.each{|fields| @database.create(fields.keys.first,fields.values.first)}
		end
	end

	def analysis
		options=@options['resultToFiles']
		@defines.puts "> Stripping parameters, detecting and classifying Third-Party content..."
		fw=nil
		@defines.puts "> Dumping to files..."
		if options[@defines.files['devices'].split("/").last] and not File.size?@defines.files['devices']
			fd=File.new(@defines.files['devices'],'w')
			@trace.devs.each{|dev| fd.puts dev}
			fd.close
		end
		if options[@defines.files['restParamsNum'].split("/").last] and not File.size?@defines.files['restParamsNum']
			fpar=File.new(@defines.files['restParamsNum'],'w')
			@trace.restNumOfParams.each{|p| fpar.puts p}
			fpar.close
		end
		if options[@defines.files['adParamsNum'].split("/").last] and not File.size?@defines.files['adParamsNum']
			fpar=File.new(@defines.files['adParamsNum'],'w')
			@trace.adNumOfParams.each{|p| fpar.puts p}
			fpar.close
		end
		if options[@defines.files['size3rdFile'].split("/").last] and not File.size?@defines.files['size3rdFile']
			fsz=File.new(@defines.files['size3rdFile'],'w')
			@trace.sizes.each{|sz| fsz.puts sz}
			fsz.close
		end
		total=Thread.new {
			@defines.puts "> Calculating Statistics about detected ads..."
			@defines.puts @trace.results_toString(@database,@defines.tables['traceTable'],@defines.tables['bcnTable'],@defines.tables['advertiserTable'],@filters.getCats)}
		perUserAnalysis()
		total.join
	end

	def findStrInRows(str)
		for val in r.values do
			if val.include? str
				if(printable)
					url=r['url'].split('?')
					Utilities.printRow(r,STDOUT)
				end
				found.push(r)					
				break
			end
		end
	end

	def parseRequest(row,browserOnly)
		if row['ua']!=-1
			mob,dev,browser=reqOrigin(row)		#CHECK THE DEVICE TYPE
			row['mob']=mob
			row['dev']=dev
			row['browser']=browser
			if browserOnly and browser.eql? "unknown"
				return false
			end		#FILTER ROW
		end
		cat=filterRow(row)
		cookieSyncing(row,cat) if @options['tablesDB'][@defines.tables["csyncTable"]]
		return true
	end

	def readUserAcrivity(tmlnFiles)
		@defines.puts "> Loading "+tmlnFiles.size.to_s+" User Activity files..."
		user_path=@cwd+@defines.userDir
		timeline_path=@cwd+@defines.userDir+@defines.tmln_path
		for tmln in tmlnFiles do
			createTmlnForUser(tmln,timeline_path,user_path)
		end
	end

	def createTimelines()
		@defines.puts "> Contructing User Timelines..."
		user_path=@cwd+@defines.userDir
		timeline_path=@cwd+@defines.userDir+@defines.tmln_path
		fr=File.new(@cwd+@defines.dataDir+"IPport_uniq",'r')
		while l=fr.gets
			user=l.chop
			fw=File.new(timeline_path+user+"_per"+(@window/1000).to_s+"sec",'w')
			IO.popen('grep '+user+' ./'+@defines.traceFile) { |io| 
			firstTime=-1
			while (line = io.gets) do 
				h=Format.columnsFormat(line,@defines.column_Format)
				Utilities.separateTimelineEvents(h,user_path+h['IPport'],@defines.column_Format)
				if firstTime==-1
					firstTime=h['tmstp'].to_i
				end
				applyTimeWindow(firstTime,row,fw)
			end }
			fw.close
		end
		fr.close
	end

	def cookieSyncing(row,cat)
		firstSeenUser?(row)
		@params_cs[@curUser]=Hash.new(nil) if @params_cs[@curUser]==nil
		urlAll=row['url'].split("?")
		return if (urlAll.last==nil)
		fields=urlAll.last.split('&')
		return if fields.size>4 # usually there are very few params_cs (only sessionids)
		ids=0
confirmed=0
		for field in fields do
			paramPair=field.split("=")
			alfa,digit=Utilities.digitAlfa(paramPair.last)
			if not @filters.is_GarbageOrEmpty?(paramPair.last) and digit>3 and alfa>4 
				ids+=1
				curHost=Utilities.calculateHost(urlAll.first)
confirmed+=1 if @params_cs[@curUser].keys.any?{ |word| paramPair.last.downcase.eql?(word)}
				if cat==nil
					cat=@filters.getCategory(urlAll,curHost,@curUser)
					cat="Other" if cat==nil
				end
				if @params_cs[@curUser][paramPair.last]==nil #first seen ID
					@params_cs[@curUser][paramPair.last]=Array.new
				else	#have seen that ID before -> possible cookieSync
					prev=@params_cs[@curUser][paramPair.last].last
					if @filters.getRootHost(prev['host'],nil)!=@filters.getRootHost(curHost,nil)
						it_is_CM(row,prev,curHost,paramPair,urlAll,ids,cat,confirmed)
					end			
				end
				@params_cs[@curUser][paramPair.last].push({"url"=>urlAll,"paramName"=>paramPair.first,"tmstp"=>row['tmstp'],"cat"=>cat,"status"=>row["status"],"host"=>curHost})
			end
		end
	#	puts row['url']+" "+ids.to_s if ids>0
	end

	def it_is_CM(row,prev,curHost,paramPair,urlAll,ids,curCat,confirmed)
#prevTimestamp|curTimestamp|hostPrev|prevCat|hostCur|curCat|paramNamePrev|userID|paramNameCur|possibleNumberOfIDs|prevStatus|curStatus|allParamsPrev|allParamsCur
		prevHost=prev['host']
		params=[prev['tmstp'],row['tmstp'],prevHost,prev['cat'],curHost,curCat,prev["paramName"], paramPair.last, paramPair.first, prev['status'],row["status"],ids,confirmed,prev['url'].last.split("&").to_s, urlAll.last.split("&").to_s]
		id=Digest::SHA256.hexdigest (params.join("|")+prev['url'].first+"|"+urlAll.first)
		@trace.users[@curUser].csync.push(params.push(id))
		if @trace.users[@curUser].csyncIDs[paramPair.last]==nil
			@trace.users[@curUser].csyncIDs[paramPair.last]=0
		end
		
		if 	@trace.users[@curUser].csyncHosts[prevHost+">"+curHost]==nil
			@trace.users[@curUser].csyncHosts[prevHost+">"+curHost]=Array.new
		end
		@trace.users[@curUser].csyncHosts[prevHost+">"+curHost].push(ids)
		@trace.users[@curUser].csyncIDs[paramPair.last]+=1
		@trace.cooksyncs+=1
	end

	def csyncResults()
		if @database!=nil
			@defines.puts "> Dumping Cookie synchronization results..."	
			@trace.dumpUserRes(@database,nil,nil,@filters)	
		end
	end
#------------------------------------------------------------------------------------------------


	private

	def firstSeenUser?(row)
		@curUser=row['IPport']
		if @trace.users[@curUser]==nil		#first seen user
			@trace.users[@curUser]=User.new	
		end
		if @trace.users[@curUser].uIPs[row['uIP']]==nil
			@trace.users[@curUser].uIPs[row['uIP']]=1
		else
			@trace.users[@curUser].uIPs[row['uIP']]+=1
		end
	end

	def	createTmlnForUser(tmln,timeline_path,user_path)
		if not tmln.eql? '.' and not tmln.eql? ".." and not File.directory?(user_path+tmln)
			fr=File.new(user_path+tmln,'r')
			fw=nil
			firstTime=-1
			bucket=0
			startBucket=-1
			endBucket=-1
			c=0
			while line=fr.gets
				r=Format.columnsFormat(line,@defines.column_Format)
				mob,dev,browser=reqOrigin(r)
				row['mob']=mob
				row['dev']=dev
				row['browser']=browser
				if browser!=nil
					if firstTime==-1
						fw=File.new(timeline_path+tmln+"_per"+@window.to_s+"msec",'w')
						firstTime=r['tmstp'].to_i
						startBucket=firstTime
					end
					nbucket=applyTimeWindow(firstTime,r,fw)
					if bucket!=nbucket						
						fw.puts "\n"+startBucket.to_s+" : "+endBucket.to_s+"-> BUCKET "+bucket.to_s
						fw.puts @trace.results_toString(@database,nil,nil)+"\n"
						bucket=nbucket
						@trace=Trace.new(@defines)
						startBucket=r['tmstp']
					end
					@curUser=r['IPport']
					if @trace.users[@curUser]==nil		#first seen user
						@trace.users[@curUser]=User.new	
					end
					filterRow(r)
					@trace.rows.push(r)
					fw.puts c.to_s+") BUCKET "+bucket.to_s+"\t"+r['tmstp']+"\t"+r['url']+"\t"+r['ua']
					endBucket=r['tmstp'].to_i
					c+=1
				end
			end
			if startBucket!=-1 && endBucket!=-1
				fw.puts "\n"+startBucket.to_s+" : "+endBucket.to_s+"-> BUCKET "+bucket.to_s
				fw.puts @trace.results_toString(@database,nil,nil)+"\n"
			end
			@trace=Trace.new(@defines)
			fr.close
			if fw!=nil
				fw.close
			end
		end
	end

	def applyTimeWindow(firstTime,row,fw)
		diff=row['tmstp'].to_i-firstTime
		wnum=diff.to_f/@window.to_i
		return wnum.to_i
	end	

	def reqOrigin(row)
		#CHECK IF ITS MOBILE USER
		mob,dev=@filters.is_MobileType?(row)   # check the device type of the request
		if mob==1
			@trace.mobDev+=1
		end
		#CHECK IF ITS ORIGINATED FROM BROWSER
		browser=@filters.is_Browser?(row)
		if browser!= "unknown"
			@trace.fromBrowser+=1
		end
        @trace.devs.push(dev)
		return mob,dev,browser
	end		

	def filterRow(row)
		firstSeenUser?(row)
		type3rd=nil
		@isBeacon=false
		url=row['url'].split("?")
		host=row['host']		
		@trace.sizes.push(row['dataSz'].to_i)
publisher=nil
		type3rd=@filters.getCategory(url,host,@curUser)
		adCat=type3rd.eql? "Advertising"
		isAd,noOfparam=beaconImprParamCkeck(row,url,publisher,adCat)
		if type3rd!=nil	and not @isBeacon #	3rd PARTY CONTENT
			collector(type3rd,row)
			@trace.party3rd[type3rd]+=1
			if not type3rd.eql? "Content"
				if type3rd.eql? "Advertising"
					ad_detected(row,noOfparam,url)
				else # SOCIAL or ANALYTICS or OTHER type
					@trace.restNumOfParams.push(noOfparam.to_i)
				end
			else	#CONTENT type
				@trace.restNumOfParams.push(noOfparam.to_i)
			end
		else
			if @isBeacon 	#Beacon
				collectAdvertiser(row)	if type3rd=="Advertising"	#Ad-related beacon
				type3rd="Beacons"
				@trace.restNumOfParams.push(noOfparam.to_i)
				@isBeacon=false
			elsif isAd==true	# Impression or ad in param
				type3rd="Advertising"
				ad_detected(row,noOfparam,url)
				@trace.party3rd[type3rd]+=1
			elsif isAd==false	
				@trace.restNumOfParams.push(noOfparam.to_i)
				if @isBeacon==false and @filters.is_Beacon?(row['url'],row['type'],true)	#Beacon NOT ad-related2
					type3rd="Beacons"
					@isBeacon=true
					beaconSave(url.first,row)
				else	# Rest
					type3rd="Other"
					@trace.party3rd[type3rd]+=1
					if (row['browser']!="unknown")
						@trace.users[@curUser].publishers.push(row)
					end
				end
				#Utilities.printStrippedURL(url,@fl)	# dump leftovers
			end
			collector(type3rd,row)
		end
		if (type3rd=="Other" or type3rd=="Content") and @options['tablesDB'][@defines.tables["visitsTable"].keys.first]
			collectInterests(url.first)
		end
		return type3rd
	end

	def collectInterests(url)
		site=url
		site=url.split("://").last if url.include? "://"
		domain=site.split("/").first
		@trace.users[@curUser].pubVisits[domain]=0 if @trace.users[@curUser].pubVisits[domain]==nil
		@trace.users[@curUser].pubVisits[domain]+=1
		topics=nil
		topics,alexaRank=@convert.analyzePublisher(domain)
		if topics!=nil
			if @trace.users[@curUser].interests==nil
				@trace.users[@curUser].interests=Hash.new(0)
			end
			topics.each{|key, value| @trace.users[@curUser].interests[key]+=value}
		end
	end

	def collector(contenType,row)
		@trace.users[@curUser].size3rdparty[contenType].push(row['dataSz'].to_i)
		@trace.users[@curUser].dur3rd[contenType].push(row['dur'].to_i)
		type=row['type']
		if type!=-1 and @options['tablesDB'][@defines.tables["userFilesTable"].keys[0]]
			if @trace.users[@curUser].fileTypes[contenType]==nil
				@trace.users[@curUser].fileTypes[contenType]={"data"=>Array.new, "gif"=>Array.new,"html"=>Array.new,"image"=>Array.new,"other"=>Array.new,"script"=>Array.new,"styling"=>Array.new,"text"=>Array.new,"video"=>Array.new} 
			end
			@trace.users[@curUser].fileTypes[contenType][type].push(row['dataSz'].to_i)
		end
	end
	def perUserAnalysis
		if @database!=nil
			@defines.print "> Dumping per user results to "
			if @options["database?"]
				@defines.puts "database..."
			else
				@defines.puts "files..."
			end
			durStats={"Advertising"=>{},"Beacons"=>{},"Social"=>{},"Analytics"=>{},"Content"=>{},"Other"=>{}}
			sizeStats={"Advertising"=>{},"Beacons"=>{},"Social"=>{},"Analytics"=>{},"Content"=>{},"Other"=>{}}
			@trace.dumpUserRes(@database,durStats,sizeStats,@filters)
		end
	end

    def detectPrice(row,keyVal,numOfPrices,numOfparams,adSize, adPosition,publisher,isAdCat)     	# Detect possible price in parameters and returns URL Parameters in String
		domainStr=row['host']
		domain,tld=Utilities.tokenizeHost(domainStr)
		host=domain+"."+tld
		if (@filters.is_inInria_PriceTagList?(host,keyVal) or @filters.has_PriceKeyword?(keyVal)) 		# Check for Keywords and if there aren't any make ad-hoc heuristic check
			priceTag=keyVal[0]
			paramVal=keyVal[1]
			type=""
			priceVal,enc=@convert.calcPriceValue(paramVal,isAdCat)
			return false if priceVal==nil
			if enc
				type="numeric"
			else
				type="encrypted"
			end
			done=false
			if @database!=nil
				id=Digest::SHA256.hexdigest (row.values.join("|")+priceTag+"|"+priceVal.to_s+"|"+type)
				time=row['tmstp']
				adx=-1,ssp=-1,dsp=-1
				interest,pubPopularity=@convert.analyzePublisher(publisher)
				upToKnowCM=@trace.users[@curUser].csync.size
				params=[type,time,domainStr,priceTag.downcase,priceVal, row['dataSz'].to_i, upToKnowCM, numOfparams, adSize, adPosition,@convert.getGeoLocation(row['uIP']),@convert.getTod(time),interest,pubPopularity,row['IPport'],ssp,dsp,-1,row['mob'],row['dev'],row['browser'],row['url'],id]
				done=@database.insert(@defines.tables['priceTable'],params)
			end
			if @database==nil or done
				if enc
					@trace.users[@curUser].numericPrices.push(priceVal)
					@trace.numericPrices+=1
				else
					@trace.users[@curUser].hashedPrices.push(priceVal)
					@trace.hashedPrices+=1
				end
			end
			return true
		end
		return false
    end

    def detectImpressions(url,row)     	#Impression term in path
        if @filters.is_Impression?(url[0])
			Utilities.printRowToDB(row,@database,@defines.tables['impTable'],nil)
			@trace.totalImps+=1
		    @trace.users[@curUser].imp.push(row)
			return true
        end
		return false
    end

	def checkParams(row,url,publisher,adCat)
     	return 0,false if (url.last==nil)
		isAd=false
adSize=-1
adPosition=-1
        fields=url.last.split('&')
		numOfPrices=0
        for field in fields do
            keyVal=field.split("=")
            if(not @filters.is_GarbageOrEmpty?(keyVal))
				if(@filters.is_Ad_param?(keyVal))
					isAd=true
				end
				if detectPrice(row,keyVal,numOfPrices,fields.length,adSize, adPosition,publisher,(adCat or isAd))
					numOfPrices+=1
					Utilities.warning ("Price Detected in Beacon\n"+row['url']) if @isBeacon
					isAd=true
				end
			end
		end
		return fields.length,isAd
	end
			
	def beaconSave(url,row)         #findBeacons
		@isBeacon=true
		urlStr=url.split("%").first.split(";").first		
		temp=urlStr.split("/")	   #beacon type
		words=temp.size
		slashes=urlStr.count("/")
		last=temp[temp.size-1]
        temp=last.split(".")
		if (temp.size==1 or words==slashes)
			type="other"
        else
			last=temp[temp.size-1]
        	type=last
		end
		@trace.party3rd["Beacons"]+=1
		tmpstp=row['tmstp'];u=row['url']
		id=Digest::SHA256.hexdigest (row.values.join("|"))
		@trace.beacons.push([tmpstp,row['IPport'],u,type,row['mob'],row['dev'],row['browser'],id])
	end

	def beaconImprParamCkeck(row,url,publisher,adCat)
        @isBeacon=false
		isAd=false
        if @filters.is_Beacon?(row['url'],row['type'],false) 		#findBeacon in URL
            beaconSave(url.first,row)
        end
        paramNum, result=checkParams(row,url,publisher,adCat)             #check ad in URL params
        if(result==true or detectImpressions(url,row))
            isAd=true
		end
		return isAd,paramNum
	end

	def ad_detected(row,noOfparam,url)
        @trace.users[@curUser].ads.push(row)
		@trace.adSize.push(row['dataSz'].to_i)
		collectAdvertiser(row)
   #     @trace.users[@curUser].adNumOfParams.push(noOfparam.to_i)
		@trace.adNumOfParams.push(noOfparam.to_i)
		if(row['mob']!=-1)
			@trace.numOfMobileAds+=1
		end
	end

	def collectAdvertiser(row)
		if row!=nil and @options['tablesDB'][@defines.tables["advertiserTable"]]
			host=row['host']
			if @trace.advertisers[host]==nil
				@trace.advertisers[host]=Advertiser.new
				@trace.advertisers[host].durPerReq=Array.new
				@trace.advertisers[host].sizePerReq=Array.new
			end
			#@trace.advertisers[host].totalReqs+=1
			@trace.advertisers[host].reqsPerUser[@curUser]+=1
			@trace.advertisers[host].durPerReq.push(row['dur'].to_i)
			@trace.advertisers[host].sizePerReq.push(row['dataSz'].to_i)
			@trace.advertisers[host].type=@convert.advertiserType(host)
		end
	end
end
