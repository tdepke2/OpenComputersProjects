local m,q,s,x,A,M,N,O,T,U,Y,Z,aa,ba,ca,da,ea,fa,ia,ja,ka,la,ma,na,qa,ra,sa,ta,ua,va="out","mnet:d",",",math,"mtuAdjusted","send","*","hostname",table,"port","broadcast",pairs,"uptime","modem","random",tonumber,"mnet","[0m","dropTime","debugLossyActive",require,"broadcastReal","sendReal","tunnel",", flags=","Route is cached, sending from device ",setmetatable,"registerDevice","retransmitTime","modem_message"local
E=ka"component"local
K=ka"computer"local
pa=ka"event"local
oa=ka"include"local
i=oa"dlog"local
b,z,R,u,o,_,D,C,w,v={},{},{},{},{},{},{},nil,x.floor(2^32),{}local
Q
local
H={}sa(z,{__index=H})b[O]=os.getenv("HOSTNAME")
or
K.address():sub(1,8)b[U]=2048
b.route=true
b.routeTime=30
b[ua]=3
b[ia]=12
function
b.registerDevice(r,B)xassert(B==nil
or(B.open
and
B.close
and
B[M]and
B[Y]),"provided proxy for device must implement open(), close(), send(), and broadcast().")v[r]=B
if
B
then
B.open(b[U])elseif
E.type(r)==ba
then
v[r]=E.proxy(r)v[r].open(b[U])elseif
E.type(r)==na
then
local
W=E.proxy(r)v[r]=sa({open=function()end,close=function()end,[M]=function(ga,G,...)return
W[M](...)end,[Y]=function(ga,...)return
W[M](...)end},{__index=W})end
return
v[r]end
function
b.getDevices()return
v
end
for
r
in
E.list(ba,true)do
b[ta](r)end
for
r
in
E.list(na,true)do
b[ta](r)end
if
E.isAvailable(ba)then
b[A]=da(K.getDeviceInfo()[E.modem.address].capacity)end
if
E.isAvailable(na)then
b[A]=x.min(da(K.getDeviceInfo()[E.tunnel.address].capacity),b[A]or
x.huge)end
b[A]=(b[A]or
8192)-150
local
r=10
local
B=0.1
local
W=0.1
local
ga=3
function
b.debugEnableLossy(G)local
function
L(F,a)local
j,f,c={},{},{}return
function(...)local
e=T.pack(...)local
h=(x[ca]()<B)if
f[1]then
h=(f[1]==1)T.remove(f,1)end
if
h
then
i[m](ba,"[31mDropped.[0m")return
true
end
local
l=(x[ca]()<W
and
x.floor(x[ca](1,ga))or
0)if
c[1]then
l=c[1]T.remove(c,1)end
if
l>0
then
i[m](ba,"[31mSwapping packet order with next ",l," packets[0m")j[#j+1]={K[aa]()+20,l,e}else
a(T.unpack(e,1,e.n))end
local
g=1
while
j[g]do
local
n=j[g]n[2]=n[2]-1
if
K[aa]()>n[1]or
n[2]<0
then
if
K[aa]()<n[1]then
a(T.unpack(n[3],1,n[3].n))end
T.remove(j,g)g=g-1
end
g=g+1
end
return
true
end
end
for
F,a
in
Z(v)do
if
G
and
not
a[ja]then
a[ma]=a[M]a[M]=L(a,a[ma])a[la]=a[Y]a[Y]=L(a,a[la])a[ja]=true
elseif
not
G
and
a[ja]then
a[M]=a[ma]a[Y]=a[la]a[ja]=false
end
end
end
local
G
function
b.debugSetSmallMTU(L)if
L
and
not
G
then
G=b[A]b[A]=r
elseif
not
L
and
G
then
b[A]=G
G=nil
end
end
function
b.getStaticRoutes()return
H
end
local
function
L(F,a,j,f,c,e,h)if
z[f]and
v[z[f][1]]then
i[m](q,ra,z[f][1]," to ",z[f][2])v[z[f][1]][M](z[f][2],b[U],F,a,j,f,c,e,h)elseif
H[N]and
v[H[N][1]]then
i[m](q,ra,H[N][1]," to ",H[N][2])v[H[N][1]][M](H[N][2],b[U],F,a,j,f,c,e,h)else
for
l,g
in
Z(v)do
g[Y](b[U],F,a,j,f,c,e,h)end
end
end
local
function
F(a,j,f,c,e,h)local
l=x[ca]()local
g=K[aa]()if
not
a
then
a=_[f]if
not
a
then
a=x.floor(x[ca](1,w))j="s1"..j
end
a=a%w+1
_[f]=a
end
R[l]=g
if
h
then
u[f..s..a]={g,l,j,c,e}end
i[m](ea,"[32mSending packet ",b[O]," -> ",f:sub(2),":",c," id=",l,", seq=",a,qa,j,", m=",e,fa)if
f:sub(2)==b[O]then
local
n=f..s..a
o[n]={g,j,c,e,da(j:match"f(%d+)")}Q=Q
or
n
return
l
end
L(l,a,j,f:sub(2),b[O],c,e)return
l
end
function
b.send(a,j,f,c,e)i.checkArgs(a,"string",j,"number",f,"string",c,"boolean",e,"boolean,nil")xassert(not
c
or
a~=N,"broadcast address not allowed for reliable packet transmission.")local
h=c
if
a==b[O]or
a=="localhost"then
a=b[O]c=false
end
a=(c
and"r"or"u")..a
local
l=c
and"r1"or""if#f<=b[A]then
F(nil,l,a,j,f,c)else
local
g=x.ceil(#f/b[A])for
n=1,g
do
F(nil,l..(n~=g
and"f0"or"f"..g),a,j,f:sub((n-1)*b[A]+1,n*b[A]),c)end
end
if
h
then
local
g=a..s.._[a]if
e
and
c
then
while
u[g]do
if
not
u[g][5]then
return
g
end
os.sleep(0.05)end
elseif
e
then
while
o[g]do
if
not
o[g][4]then
return
g
end
os.sleep(0.05)end
else
return
g
end
end
end
local
function
a(j)local
f,c=j:match"(.*),([^,]+)$"return
f,da(c)end
local
function
j(f,c)local
e,h=a(f)if
c
and
not
c[5]then
local
l=c[4]c[4]=nil
return
e:sub(2),c[3],l
end
while
c
and
c[5]==0
do
h=h%w+1
c=o[e..s..h]end
if
c
then
local
l={}for
g=c[5],1,-1
do
local
n=o[e..s..h]i[m](q,"Collecting fragment ",e..s..h)if
not(n
and
n[4])then
return
end
l[g]=n[4]h=(h-2)%w+1
end
for
g=1,c[5]do
h=h%w+1
i[m](q,"Removing ",e..s..h," from cache.")o[e..s..h][4]=nil
end
return
e:sub(2),c[3],T.concat(l)end
end
function
b.receive(f,c)i.checkArgs(f,"number",c,"function,nil")if
C
or
Q
then
if
not
C
or
C==Q
then
C=Q
Q=nil
end
local
e,h,l=C,a(C)i[m](q,"Buffered data ready, hostSeq=",e,", type(packet)=",type(o[e]))if
o[e]then
C=h..s..l%w+1
if
not
o[e][4]then
return
end
i[m](q,"Attempting return of buffered packet ",e,", dat=",o[e])return
j(e,o[e])else
C=nil
end
end
local
e,h,l,g,n,V,y,J,X,k,P,ha=pa.pull(f,va)local
I=K[aa]()for
p,d
in
Z(u)do
if
I>d[1]+b[ia]then
if
d[5]then
i[m](ea,"[33mPacket ",p," timed out, dat=",d,fa)if
c
then
c(p,d[4],d[5])end
end
u[p]=nil
elseif
d[5]and
I>R[d[2]]+b[ua]then
i[m](q,"Retransmitting packet with previous id ",d[2])local
t,S=a(p)d[2]=F(S,d[3],t,d[4],d[5])end
end
for
p,d
in
Z(R)do
if
I>d+b[ia]then
R[p]=nil
end
end
for
p,d
in
Z(z)do
if
I>d[3]+b.routeTime
then
i[m](q,"Removing stale routing entry for host ",p)z[p]=nil
end
end
if
e~=va
or(g~=b[U]and
g~=0)or
R[V]then
return
end
y=x.floor(y)P=x.floor(P)for
p,d
in
Z(o)do
if
I>d[1]+b[ia]then
if
d[4]then
i[m](ea,"[33mDropping receivedPacket ",p,fa)end
o[p]=nil
end
end
i[m](ea,"[36mGot packet ",k," -> ",X,":",P," id=",V,", seq=",y,qa,J,", m=",ha,fa)R[V]=I
if
not(z[k]or
H[N])then
z[k]={h,l,I}end
if
X~=b[O]and
b.route
then
i[m](ea,"[32mRouting packet ",V,fa)L(V,y,J,X,k,P,ha)end
if
X==b[O]or
X==N
then
local
p=J:find"[ra]1"k=(p
and"r"or"u")..k
local
d=k..s..y
if
J=="a1"then
if
u[d]then
while
u[d]and
u[d][5]do
i[m](q,"Marking ",d," as acknowledged.")u[d][5]=nil
y=(y-2)%w+1
d=k..s..y
end
else
local
t=_[k]or
0
repeat
t=(t-2)%w+1
d=k..s..t
until
not(u[d]and
u[d][5])d=k..s..t%w+1
i[m](q,"Found unexpected ack, beforeFirstSequence is ",t,", first hostSeq is ",d)local
S=u[d]if
t~=y
and
S
and
not
S[3]:find"s1"then
i[m](q,"Setting syn flag for hostSeq.")S[3]=S[3].."s1"end
end
return
end
local
t
if
not
o[d]or
o[d][4]then
t={I,J,P,ha,da(J:match"f(%d+)")}o[d]=t
if
not
p
then
i[m](q,"Ignored ordering, passing packet through.")elseif
J:find"s1"or
D[k]and
D[k]%w+1==y
then
if
J:find"s1"then
i[m](q,"Begin new connection to ",k:sub(2))else
i[m](q,"Packet arrived in expected order.")end
D[k]=y
while
o[k..s..D[k]%w+1]do
D[k]=D[k]%w+1
i[m](q,"Buffered packet ready, bumped last sequence to ",D[k])C=C
or
k..s..D[k]end
else
i[m](q,"Packet arrived in unexpected order (last sequence was ",D[k],")")t=nil
end
else
i[m](q,"Already processed this sequence, ignoring.")end
if
p
then
F(D[k]or
0,"a1",k,P)end
return
j(d,t)end
end
return
b