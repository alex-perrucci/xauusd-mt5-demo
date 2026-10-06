#property strict
#property version   "2.00"
#property description "XAUUSD demo-only GitHub signal executor with pending orders and state export"

#define SIGNAL_FILE        "xauusd\\signal.txt"
#define GUARD_FILE         "xauusd\\guard.txt"
#define ACK_FILE           "xauusd\\ack.txt"
#define STATE_FILE         "xauusd\\state.txt"
#define LAST_SIGNAL_FILE   "xauusd\\last_signal.txt"
#define PENDING_META_FILE  "xauusd\\pending_meta.txt"
#define ABS_MAX_RISK_PCT   0.5
#define ABS_MAX_VOLUME     0.01
#define ABS_MIN_RR         2.0

struct GuardConfig
  {
   long   expected_login;
   string expected_server;
   string broker_symbol;
   double max_spread_points;
   double max_risk_pct;
   double min_rr;
   ulong  magic;
   ulong  deviation_points;
  };

struct BridgeSignal
  {
   int      schema;
   string   id;
   string   action;
   string   logical_symbol;
   bool     has_entry;
   double   entry;
   bool     has_sl;
   double   sl;
   bool     has_tp;
   double   tp;
   double   risk_pct;
   long     created_epoch;
   long     valid_epoch;
  };

string g_last_signal_id="";

int OnInit()
  {
   g_last_signal_id=ReadSmallFile(LAST_SIGNAL_FILE);
   EventSetTimer(1);
   Print("SignalBridge v2 initialized. Data path=",TerminalInfoString(TERMINAL_DATA_PATH));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   CancelExpiredPending();
   WriteState();
   ProcessBridge();
  }

string ReadSmallFile(const string file_name)
  {
   int h=FileOpen(file_name,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return "";
   string value=FileReadString(h);
   FileClose(h);
   return value;
  }

bool WriteSmallFile(const string file_name,const string value)
  {
   int h=FileOpen(file_name,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return false;
   FileWriteString(h,value+"\r\n");
   FileFlush(h);
   FileClose(h);
   return true;
  }

void ClearSmallFile(const string file_name)
  {
   WriteSmallFile(file_name,"");
  }

long BrokerUtcOffsetSeconds()
  {
   return (long)TimeCurrent()-(long)TimeGMT();
  }

datetime UtcEpochToBrokerTime(const long utc_epoch)
  {
   return (datetime)(utc_epoch+BrokerUtcOffsetSeconds());
  }

long BrokerTimeToUtcEpoch(const datetime broker_time)
  {
   return (long)broker_time-BrokerUtcOffsetSeconds();
  }

void Acknowledge(const string id,const string status,const string message)
  {
   string safe_message=message;
   StringReplace(safe_message,"|","/");
   StringReplace(safe_message,"\r"," ");
   StringReplace(safe_message,"\n"," ");
   string line=id+"|"+status+"|"+IntegerToString((int)TimeGMT())+"|"+safe_message;
   WriteSmallFile(ACK_FILE,line);
  }

void FinishSignal(const string id,const string status,const string message)
  {
   g_last_signal_id=id;
   WriteSmallFile(LAST_SIGNAL_FILE,id);
   Acknowledge(id,status,message);
   Print("signal ",id," -> ",status,": ",message);
  }

bool LoadGuard(GuardConfig &guard,string &error)
  {
   string line=ReadSmallFile(GUARD_FILE);
   if(line=="")
     {
      error="guard file missing or empty";
      return false;
     }

   string f[];
   ushort delimiter=StringGetCharacter("|",0);
   int count=StringSplit(line,delimiter,f);
   if(count!=9 || f[0]!="1")
     {
      error="invalid guard format";
      return false;
     }

   guard.expected_login=(long)StringToInteger(f[1]);
   guard.expected_server=f[2];
   guard.broker_symbol=f[3];
   guard.max_spread_points=StringToDouble(f[4]);
   guard.max_risk_pct=MathMin(StringToDouble(f[5]),ABS_MAX_RISK_PCT);
   guard.min_rr=MathMax(StringToDouble(f[6]),ABS_MIN_RR);
   guard.magic=(ulong)StringToInteger(f[7]);
   guard.deviation_points=(ulong)StringToInteger(f[8]);

   if(guard.expected_login<=0 || guard.expected_server=="" || guard.broker_symbol=="")
     {
      error="guard account/server/symbol is incomplete";
      return false;
     }
   if(guard.max_spread_points<=0 || guard.max_risk_pct<=0 || guard.magic==0)
     {
      error="guard risk/spread/magic is invalid";
      return false;
     }
   return true;
  }

bool LoadSignal(BridgeSignal &signal,string &error)
  {
   string line=ReadSmallFile(SIGNAL_FILE);
   if(line=="")
      return false;

   string f[];
   ushort delimiter=StringGetCharacter("|",0);
   int count=StringSplit(line,delimiter,f);
   if(count!=10)
     {
      error="invalid signal field count";
      return false;
     }

   signal.schema=(int)StringToInteger(f[0]);
   signal.id=f[1];
   signal.action=f[2];
   signal.logical_symbol=f[3];
   signal.has_entry=(f[4]!="");
   signal.entry=signal.has_entry ? StringToDouble(f[4]) : 0.0;
   signal.has_sl=(f[5]!="");
   signal.sl=signal.has_sl ? StringToDouble(f[5]) : 0.0;
   signal.has_tp=(f[6]!="");
   signal.tp=signal.has_tp ? StringToDouble(f[6]) : 0.0;
   signal.risk_pct=StringToDouble(f[7]);
   signal.created_epoch=(long)StringToInteger(f[8]);
   signal.valid_epoch=(long)StringToInteger(f[9]);

   if(signal.schema!=2 || signal.id=="" || signal.logical_symbol!="XAUUSD")
     {
      error="invalid schema/id/logical symbol";
      return false;
     }
   return true;
  }

bool IsKnownAction(const string action)
  {
   return action=="NO_TRADE" || action=="HOLD" || action=="STATUS" ||
          action=="BUY" || action=="SELL" ||
          action=="BUY_STOP" || action=="SELL_STOP" ||
          action=="CLOSE" || action=="CANCEL" || action=="MODIFY";
  }

bool CheckAccountGuard(const GuardConfig &guard,string &error)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      error="terminal not connected";
      return false;
     }
   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
     {
      error="account is not DEMO";
      return false;
     }
   if((long)AccountInfoInteger(ACCOUNT_LOGIN)!=guard.expected_login)
     {
      error="unexpected account login";
      return false;
     }
   if(AccountInfoString(ACCOUNT_SERVER)!=guard.expected_server)
     {
      error="unexpected account server";
      return false;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      error="automated trading is disabled";
      return false;
     }
   return true;
  }

int VolumeDigits(const double step)
  {
   int digits=0;
   double scaled=step;
   while(digits<8 && MathAbs(scaled-MathRound(scaled))>1e-9)
     {
      scaled*=10.0;
      digits++;
     }
   return digits;
  }

double NormalizeRiskVolume(const string symbol,const ENUM_ORDER_TYPE side_type,const double entry,const double sl,const double risk_pct,string &error)
  {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount=equity*(risk_pct/100.0);
   if(equity<=0 || risk_amount<=0)
     {
      error="invalid equity/risk amount";
      return 0.0;
     }

   double one_lot_profit=0.0;
   if(!OrderCalcProfit(side_type,symbol,1.0,entry,sl,one_lot_profit))
     {
      error="OrderCalcProfit failed";
      return 0.0;
     }
   double one_lot_loss=MathAbs(one_lot_profit);
   if(one_lot_loss<=0)
     {
      error="one-lot SL loss is zero";
      return 0.0;
     }

   double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double broker_vmax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double vmax=MathMin(broker_vmax,ABS_MAX_VOLUME);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(vmin<=0 || broker_vmax<=0 || step<=0)
     {
      error="invalid broker volume constraints";
      return 0.0;
     }
   if(vmin>ABS_MAX_VOLUME)
     {
      error="broker minimum volume exceeds hard safety cap";
      return 0.0;
     }

   double raw=risk_amount/one_lot_loss;
   if(raw<vmin)
     {
      error="required volume below broker minimum; refusing to exceed risk cap";
      return 0.0;
     }

   double volume=MathFloor((MathMin(raw,vmax)+1e-12)/step)*step;
   volume=NormalizeDouble(volume,VolumeDigits(step));

   double actual_profit=0.0;
   if(volume<=0 || !OrderCalcProfit(side_type,symbol,volume,entry,sl,actual_profit))
     {
      error="volume risk verification failed";
      return 0.0;
     }
   if(MathAbs(actual_profit)>risk_amount*1.01)
     {
      error="normalized volume exceeds risk cap";
      return 0.0;
     }
   return volume;
  }

ENUM_ORDER_TYPE_FILLING FillingMode(const string symbol)
  {
   long filling=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   long execution=SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
   if((filling & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if(execution!=SYMBOL_TRADE_EXECUTION_MARKET)
      return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
  }

bool HasAnySymbolExposure(const string symbol)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)==symbol)
         return true;
     }

   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0)
         continue;
      if(OrderGetString(ORDER_SYMBOL)==symbol)
         return true;
     }
   return false;
  }

bool IsManagedPosition(const string symbol,const ulong magic)
  {
   return PositionGetString(POSITION_SYMBOL)==symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==magic;
  }

bool IsManagedOrder(const string symbol,const ulong magic)
  {
   return OrderGetString(ORDER_SYMBOL)==symbol && (ulong)OrderGetInteger(ORDER_MAGIC)==magic;
  }

bool SendChecked(MqlTradeRequest &request,MqlTradeResult &result,string &message)
  {
   MqlTradeCheckResult check={};
   ResetLastError();
   if(!OrderCheck(request,check))
     {
      message="OrderCheck failed: "+check.comment+" err="+IntegerToString(GetLastError());
      return false;
     }

   ResetLastError();
   if(!OrderSend(request,result))
     {
      message="OrderSend failed: err="+IntegerToString(GetLastError());
      return false;
     }

   if(result.retcode!=TRADE_RETCODE_DONE &&
      result.retcode!=TRADE_RETCODE_PLACED &&
      result.retcode!=TRADE_RETCODE_DONE_PARTIAL)
     {
      message="trade rejected retcode="+IntegerToString((int)result.retcode)+" "+result.comment;
      return false;
     }
   message="retcode="+IntegerToString((int)result.retcode)+" deal="+(string)result.deal+" order="+(string)result.order;
   return true;
  }

bool ValidateGeometry(const bool is_buy,const double entry,const double sl,const double tp,const double min_rr,double &rr,string &message)
  {
   double risk_distance=is_buy ? entry-sl : sl-entry;
   double reward_distance=is_buy ? tp-entry : entry-tp;
   if(risk_distance<=0 || reward_distance<=0)
     {
      message="invalid SL/entry/TP geometry";
      return false;
     }
   rr=reward_distance/risk_distance;
   if(rr<min_rr || rr<ABS_MIN_RR)
     {
      message="RR below minimum: "+DoubleToString(rr,2);
      return false;
     }
   return true;
  }

bool CheckSpread(const string symbol,MqlTick &tick,string &message,const GuardConfig &guard)
  {
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
     {
      message="no live tick";
      return false;
     }
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(point<=0)
     {
      message="invalid point size";
      return false;
     }
   double spread=(tick.ask-tick.bid)/point;
   if(spread>guard.max_spread_points)
     {
      message="spread too high: "+DoubleToString(spread,1);
      return false;
     }
   return true;
  }

bool OpenMarket(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   if(!SymbolSelect(symbol,true))
     {
      message="broker symbol unavailable";
      return false;
     }
   if(HasAnySymbolExposure(symbol))
     {
      message="existing broker-symbol exposure; stacking blocked";
      return false;
     }
   if(!signal.has_sl || !signal.has_tp || signal.sl<=0 || signal.tp<=0)
     {
      message="SL and TP are mandatory";
      return false;
     }
   if(signal.risk_pct<=0 || signal.risk_pct>guard.max_risk_pct || signal.risk_pct>ABS_MAX_RISK_PCT)
     {
      message="risk exceeds local cap";
      return false;
     }

   MqlTick tick={};
   if(!CheckSpread(symbol,tick,message,guard))
      return false;

   bool is_buy=(signal.action=="BUY");
   ENUM_ORDER_TYPE type=is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry=is_buy ? tick.ask : tick.bid;
   double rr=0.0;
   if(!ValidateGeometry(is_buy,entry,signal.sl,signal.tp,guard.min_rr,rr,message))
      return false;

   string error="";
   double volume=NormalizeRiskVolume(symbol,type,entry,signal.sl,signal.risk_pct,error);
   if(volume<=0)
     {
      message=error;
      return false;
     }

   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   MqlTradeRequest request={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_DEAL;
   request.symbol=symbol;
   request.volume=volume;
   request.type=type;
   request.price=NormalizeDouble(entry,digits);
   request.sl=NormalizeDouble(signal.sl,digits);
   request.tp=NormalizeDouble(signal.tp,digits);
   request.deviation=guard.deviation_points;
   request.magic=guard.magic;
   request.comment="cgpt-demo:"+StringSubstr(signal.id,0,12);
   request.type_time=ORDER_TIME_GTC;
   request.type_filling=FillingMode(symbol);

   return SendChecked(request,result,message);
  }

void SavePendingMeta(const ulong ticket,const long valid_epoch)
  {
   WriteSmallFile(PENDING_META_FILE,(string)ticket+"|"+(string)valid_epoch);
  }

bool PlacePending(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   if(!SymbolSelect(symbol,true))
     {
      message="broker symbol unavailable";
      return false;
     }
   if(HasAnySymbolExposure(symbol))
     {
      message="existing broker-symbol exposure; stacking blocked";
      return false;
     }
   if(!signal.has_entry || !signal.has_sl || !signal.has_tp ||
      signal.entry<=0 || signal.sl<=0 || signal.tp<=0)
     {
      message="entry, SL and TP are mandatory for pending orders";
      return false;
     }
   if(signal.risk_pct<=0 || signal.risk_pct>guard.max_risk_pct || signal.risk_pct>ABS_MAX_RISK_PCT)
     {
      message="risk exceeds local cap";
      return false;
     }

   MqlTick tick={};
   if(!CheckSpread(symbol,tick,message,guard))
      return false;

   bool is_buy=(signal.action=="BUY_STOP");
   if(is_buy && signal.entry<=tick.ask)
     {
      message="BUY_STOP entry must be above current ask";
      return false;
     }
   if(!is_buy && signal.entry>=tick.bid)
     {
      message="SELL_STOP entry must be below current bid";
      return false;
     }

   double rr=0.0;
   if(!ValidateGeometry(is_buy,signal.entry,signal.sl,signal.tp,guard.min_rr,rr,message))
      return false;

   ENUM_ORDER_TYPE calc_type=is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string error="";
   double volume=NormalizeRiskVolume(symbol,calc_type,signal.entry,signal.sl,signal.risk_pct,error);
   if(volume<=0)
     {
      message=error;
      return false;
     }

   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   MqlTradeRequest request={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_PENDING;
   request.symbol=symbol;
   request.volume=volume;
   request.type=is_buy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   request.price=NormalizeDouble(signal.entry,digits);
   request.sl=NormalizeDouble(signal.sl,digits);
   request.tp=NormalizeDouble(signal.tp,digits);
   request.magic=guard.magic;
   request.comment="cgpt-demo:"+StringSubstr(signal.id,0,12);
   request.type_filling=ORDER_FILLING_RETURN;

   long expiration_modes=SymbolInfoInteger(symbol,SYMBOL_EXPIRATION_MODE);
   if((expiration_modes & SYMBOL_EXPIRATION_SPECIFIED)==SYMBOL_EXPIRATION_SPECIFIED)
     {
      request.type_time=ORDER_TIME_SPECIFIED;
      request.expiration=UtcEpochToBrokerTime(signal.valid_epoch);
     }
   else
     {
      request.type_time=ORDER_TIME_GTC;
     }

   bool ok=SendChecked(request,result,message);
   if(ok && result.order>0)
      SavePendingMeta(result.order,signal.valid_epoch);
   return ok;
  }

bool CancelManagedPending(const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   bool found=false;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !IsManagedOrder(symbol,guard.magic))
         continue;
      found=true;
      MqlTradeRequest request={};
      MqlTradeResult result={};
      request.action=TRADE_ACTION_REMOVE;
      request.order=ticket;
      request.magic=guard.magic;
      if(!SendChecked(request,result,message))
         return false;
     }
   ClearSmallFile(PENDING_META_FILE);
   message=found ? "managed pending order(s) cancelled" : "no managed pending order";
   return true;
  }

void CancelExpiredPending()
  {
   string meta=ReadSmallFile(PENDING_META_FILE);
   if(meta=="")
      return;

   string f[];
   ushort delimiter=StringGetCharacter("|",0);
   if(StringSplit(meta,delimiter,f)!=2)
     {
      ClearSmallFile(PENDING_META_FILE);
      return;
     }

   ulong ticket=(ulong)StringToInteger(f[0]);
   long valid_epoch=(long)StringToInteger(f[1]);
   if(ticket==0 || valid_epoch<=0)
     {
      ClearSmallFile(PENDING_META_FILE);
      return;
     }
   if((long)TimeGMT()<=valid_epoch)
      return;

   GuardConfig guard={};
   string error="";
   if(!LoadGuard(guard,error))
      return;
   if(!CheckAccountGuard(guard,error))
      return;

   if(!OrderSelect(ticket))
     {
      ClearSmallFile(PENDING_META_FILE);
      return;
     }
   if(!IsManagedOrder(guard.broker_symbol,guard.magic))
     {
      ClearSmallFile(PENDING_META_FILE);
      return;
     }

   MqlTradeRequest request={};
   MqlTradeResult result={};
   string message="";
   request.action=TRADE_ACTION_REMOVE;
   request.order=ticket;
   request.magic=guard.magic;
   if(SendChecked(request,result,message))
     {
      ClearSmallFile(PENDING_META_FILE);
      Acknowledge("expiry-"+(string)ticket,"OK","expired pending cancelled");
      Print("expired pending ",ticket," cancelled");
     }
  }

bool CloseManaged(const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   bool found=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(symbol,guard.magic))
         continue;
      found=true;
      MqlTick tick={};
      if(!SymbolInfoTick(symbol,tick))
        {
         message="no tick while closing";
         return false;
        }
      long position_type=PositionGetInteger(POSITION_TYPE);
      double volume=PositionGetDouble(POSITION_VOLUME);
      ENUM_ORDER_TYPE type=(position_type==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      MqlTradeRequest request={};
      MqlTradeResult result={};
      request.action=TRADE_ACTION_DEAL;
      request.position=ticket;
      request.symbol=symbol;
      request.volume=volume;
      request.type=type;
      request.price=(type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
      request.deviation=guard.deviation_points;
      request.magic=guard.magic;
      request.comment="cgpt-close";
      request.type_time=ORDER_TIME_GTC;
      request.type_filling=FillingMode(symbol);
      if(!SendChecked(request,result,message))
         return false;
     }
   message=found ? "managed position(s) closed" : "no managed position open";
   return true;
  }

bool ModifyManaged(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   bool found=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(symbol,guard.magic))
         continue;
      found=true;
      MqlTick tick={};
      if(!SymbolInfoTick(symbol,tick))
        {
         message="no tick while modifying";
         return false;
        }
      long position_type=PositionGetInteger(POSITION_TYPE);
      double sl=signal.has_sl ? signal.sl : PositionGetDouble(POSITION_SL);
      double tp=signal.has_tp ? signal.tp : PositionGetDouble(POSITION_TP);
      if(position_type==POSITION_TYPE_BUY)
        {
         if((sl>0 && sl>=tick.bid) || (tp>0 && tp<=tick.bid))
           {
            message="invalid BUY SL/TP modification";
            return false;
           }
        }
      else
        {
         if((sl>0 && sl<=tick.ask) || (tp>0 && tp>=tick.ask))
           {
            message="invalid SELL SL/TP modification";
            return false;
           }
        }

      int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      MqlTradeRequest request={};
      MqlTradeResult result={};
      request.action=TRADE_ACTION_SLTP;
      request.position=ticket;
      request.symbol=symbol;
      request.sl=sl>0 ? NormalizeDouble(sl,digits) : 0.0;
      request.tp=tp>0 ? NormalizeDouble(tp,digits) : 0.0;
      request.magic=guard.magic;
      if(!SendChecked(request,result,message))
         return false;
     }
   if(!found)
     {
      message="no managed position to modify";
      return false;
     }
   message="managed position modified";
   return true;
  }

void WriteState()
  {
   GuardConfig guard={};
   string error="";
   if(!LoadGuard(guard,error))
      return;

   string symbol=guard.broker_symbol;
   SymbolSelect(symbol,true);
   MqlTick tick={};
   bool has_tick=SymbolInfoTick(symbol,tick);

   int connected=(int)TerminalInfoInteger(TERMINAL_CONNECTED);
   int demo=((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO) ? 1 : 0;
   int trade_allowed=(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
                      MQLInfoInteger(MQL_TRADE_ALLOWED) &&
                      AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) ? 1 : 0;

   int pos_count=0;
   string pos_type="";
   string pos_ticket="";
   string pos_volume="";
   string pos_open="";
   string pos_sl="";
   string pos_tp="";
   string pos_profit="";

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(symbol,guard.magic))
         continue;
      pos_count++;
      if(pos_count==1)
        {
         long ptype=PositionGetInteger(POSITION_TYPE);
         pos_type=(ptype==POSITION_TYPE_BUY) ? "BUY" : "SELL";
         pos_ticket=(string)ticket;
         pos_volume=DoubleToString(PositionGetDouble(POSITION_VOLUME),8);
         pos_open=DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),8);
         pos_sl=DoubleToString(PositionGetDouble(POSITION_SL),8);
         pos_tp=DoubleToString(PositionGetDouble(POSITION_TP),8);
         pos_profit=DoubleToString(PositionGetDouble(POSITION_PROFIT),2);
        }
     }

   int order_count=0;
   string order_type="";
   string order_ticket="";
   string order_price="";
   string order_sl="";
   string order_tp="";

   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !IsManagedOrder(symbol,guard.magic))
         continue;
      order_count++;
      if(order_count==1)
        {
         ENUM_ORDER_TYPE otype=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         order_type=EnumToString(otype);
         order_ticket=(string)ticket;
         order_price=DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN),8);
         order_sl=DoubleToString(OrderGetDouble(ORDER_SL),8);
         order_tp=DoubleToString(OrderGetDouble(ORDER_TP),8);
        }
     }

   string last_deal_ticket="";
   string last_position_id="";
   string last_deal_type="";
   string last_deal_reason="";
   string last_deal_price="";
   string last_deal_profit="";
   string last_deal_time="";

   datetime history_to=TimeCurrent();
   datetime history_from=history_to-(60*24*60*60);
   if(HistorySelect(history_from,history_to))
     {
      for(int i=HistoryDealsTotal()-1;i>=0;i--)
        {
         ulong deal_ticket=HistoryDealGetTicket(i);
         if(deal_ticket==0)
            continue;
         if(HistoryDealGetString(deal_ticket,DEAL_SYMBOL)!=symbol)
            continue;
         if((ulong)HistoryDealGetInteger(deal_ticket,DEAL_MAGIC)!=guard.magic)
            continue;

         ENUM_DEAL_ENTRY deal_entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket,DEAL_ENTRY);
         if(deal_entry!=DEAL_ENTRY_OUT && deal_entry!=DEAL_ENTRY_OUT_BY)
            continue;

         last_deal_ticket=(string)deal_ticket;
         last_position_id=(string)HistoryDealGetInteger(deal_ticket,DEAL_POSITION_ID);
         last_deal_type=EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket,DEAL_TYPE));
         last_deal_reason=EnumToString((ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket,DEAL_REASON));
         last_deal_price=DoubleToString(HistoryDealGetDouble(deal_ticket,DEAL_PRICE),8);
         last_deal_profit=DoubleToString(HistoryDealGetDouble(deal_ticket,DEAL_PROFIT),2);
         last_deal_time=(string)HistoryDealGetInteger(deal_ticket,DEAL_TIME);
         break;
        }
     }

   string bid=has_tick ? DoubleToString(tick.bid,8) : "";
   string ask=has_tick ? DoubleToString(tick.ask,8) : "";
   string line=
      "1|"+(string)((long)TimeGMT())+
      "|"+IntegerToString(connected)+
      "|"+IntegerToString(demo)+
      "|"+IntegerToString(trade_allowed)+
      "|"+symbol+
      "|"+bid+
      "|"+ask+
      "|"+IntegerToString(pos_count)+
      "|"+pos_type+
      "|"+pos_ticket+
      "|"+pos_volume+
      "|"+pos_open+
      "|"+pos_sl+
      "|"+pos_tp+
      "|"+pos_profit+
      "|"+IntegerToString(order_count)+
      "|"+order_type+
      "|"+order_ticket+
      "|"+order_price+
      "|"+order_sl+
      "|"+order_tp+
      "|"+last_deal_ticket+
      "|"+last_position_id+
      "|"+last_deal_type+
      "|"+last_deal_reason+
      "|"+last_deal_price+
      "|"+last_deal_profit+
      "|"+last_deal_time+
      "|"+g_last_signal_id;

   WriteSmallFile(STATE_FILE,line);
  }

void ProcessBridge()
  {
   BridgeSignal signal={};
   string error="";
   if(!LoadSignal(signal,error))
      return;
   if(signal.id==g_last_signal_id)
      return;

   if(!IsKnownAction(signal.action))
     {
      FinishSignal(signal.id,"BLOCKED","unknown action");
      return;
     }
   if(signal.valid_epoch<=0 || (long)TimeGMT()>signal.valid_epoch)
     {
      FinishSignal(signal.id,"BLOCKED","signal expired");
      return;
     }
   if(signal.action=="NO_TRADE" || signal.action=="HOLD" || signal.action=="STATUS")
     {
      WriteState();
      FinishSignal(signal.id,"OK",signal.action+" acknowledged");
      return;
     }

   GuardConfig guard={};
   if(!LoadGuard(guard,error))
     {
      Print("guard unavailable: ",error);
      return;
     }
   if(!CheckAccountGuard(guard,error))
     {
      if(error=="terminal not connected" || error=="automated trading is disabled")
        {
         Print("waiting: ",error);
         return;
        }
      FinishSignal(signal.id,"BLOCKED",error);
      return;
     }

   string message="";
   bool ok=false;
   if(signal.action=="BUY" || signal.action=="SELL")
      ok=OpenMarket(signal,guard,message);
   else if(signal.action=="BUY_STOP" || signal.action=="SELL_STOP")
      ok=PlacePending(signal,guard,message);
   else if(signal.action=="CLOSE")
      ok=CloseManaged(guard,message);
   else if(signal.action=="CANCEL")
      ok=CancelManagedPending(guard,message);
   else if(signal.action=="MODIFY")
      ok=ModifyManaged(signal,guard,message);

   FinishSignal(signal.id,ok ? "OK" : "BLOCKED",message);
   WriteState();
  }
